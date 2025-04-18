#!/bin/bash

# 创建notebook内容
cat > colab_training.ipynb << 'EOL'
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# DeepSeek-R1-Distill-Qwen-1.5B 模型微调实验\n",
    "\n",
    "本笔记本将指导您完成模型微调的整个过程。"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 1. 环境准备\n",
    "首先安装必要的依赖包"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "!pip install -q transformers==4.35.2 datasets accelerate bitsandbytes==0.41.1 peft==0.7.1 torch==2.1.0"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 2. 检查 GPU 环境"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "import torch\n",
    "print(\"GPU available:\", torch.cuda.is_available())\n",
    "print(\"GPU device name:\", torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"No GPU\")"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 3. 创建训练代码"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "%%writefile train_colab.py\n",
    "\n",
    "import torch\n",
    "from datasets import load_dataset\n",
    "from transformers import (\n",
    "    AutoModelForCausalLM,\n",
    "    AutoTokenizer,\n",
    "    TrainingArguments,\n",
    "    Trainer,\n",
    "    DataCollatorForLanguageModeling\n",
    ")\n",
    "from peft import (\n",
    "    prepare_model_for_kbit_training,\n",
    "    LoraConfig,\n",
    "    get_peft_model,\n",
    "    TaskType\n",
    ")\n",
    "import os\n",
    "from google.colab import drive\n",
    "\n",
    "def mount_drive():\n",
    "    drive.mount('/content/drive')\n",
    "    os.makedirs('/content/drive/MyDrive/model_training', exist_ok=True)\n",
    "    return '/content/drive/MyDrive/model_training'\n",
    "\n",
    "def create_sample_dataset():\n",
    "    data = {\n",
    "        \"instruction\": [\n",
    "            \"解释什么是机器学习\",\n",
    "            \"写一个简单的Python函数\",\n",
    "            \"总结以下文本的主要内容\"\n",
    "        ],\n",
    "        \"input\": [\n",
    "            \"\",\n",
    "            \"计算两个数的和\",\n",
    "            \"人工智能是计算机科学的一个重要分支...\"\n",
    "        ],\n",
    "        \"output\": [\n",
    "            \"机器学习是人工智能的一个子领域，它使计算机系统能够通过经验自动改进...\",\n",
    "            \"def add_numbers(a, b):\\\\n    return a + b\",\n",
    "            \"这段文本主要讨论了人工智能的概念和应用...\"\n",
    "        ]\n",
    "    }\n",
    "    \n",
    "    import json\n",
    "    with open('sample_data.json', 'w', encoding='utf-8') as f:\n",
    "        json.dump({\"train\": data}, f, ensure_ascii=False, indent=2)\n",
    "\n",
    "def load_model_and_tokenizer():\n",
    "    model_name = \"deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B\"\n",
    "    \n",
    "    model = AutoModelForCausalLM.from_pretrained(\n",
    "        model_name,\n",
    "        trust_remote_code=True,\n",
    "        load_in_8bit=True,\n",
    "        device_map=\"auto\"\n",
    "    )\n",
    "    \n",
    "    tokenizer = AutoTokenizer.from_pretrained(\n",
    "        model_name,\n",
    "        trust_remote_code=True\n",
    "    )\n",
    "    return model, tokenizer\n",
    "\n",
    "def prepare_model_for_training(model):\n",
    "    lora_config = LoraConfig(\n",
    "        task_type=TaskType.CAUSAL_LM,\n",
    "        r=4,\n",
    "        lora_alpha=16,\n",
    "        lora_dropout=0.1,\n",
    "        target_modules=[\"q_proj\", \"k_proj\", \"v_proj\", \"o_proj\"],\n",
    "        bias=\"none\",\n",
    "        inference_mode=False,\n",
    "    )\n",
    "    \n",
    "    model = prepare_model_for_kbit_training(model)\n",
    "    model = get_peft_model(model, lora_config)\n",
    "    return model\n",
    "\n",
    "def prepare_dataset(tokenizer, data_path):\n",
    "    dataset = load_dataset(\"json\", data_files=data_path)\n",
    "    \n",
    "    def preprocess_function(examples):\n",
    "        prompts = []\n",
    "        for instruction, input_text in zip(examples[\"instruction\"], examples[\"input\"]):\n",
    "            if input_text:\n",
    "                prompt = f\"Instruction: {instruction}\\\\nInput: {input_text}\\\\nOutput: \"\n",
    "            else:\n",
    "                prompt = f\"Instruction: {instruction}\\\\nOutput: \"\n",
    "            prompts.append(prompt)\n",
    "        \n",
    "        texts = [p + o for p, o in zip(prompts, examples[\"output\"])]\n",
    "        \n",
    "        encodings = tokenizer(\n",
    "            texts,\n",
    "            truncation=True,\n",
    "            max_length=256,\n",
    "            padding=\"max_length\",\n",
    "            return_tensors=\"pt\"\n",
    "        )\n",
    "        return encodings\n",
    "\n",
    "    processed_dataset = dataset[\"train\"].map(\n",
    "        preprocess_function,\n",
    "        remove_columns=dataset[\"train\"].column_names,\n",
    "        batch_size=4,\n",
    "    )\n",
    "    return processed_dataset\n",
    "\n",
    "def main():\n",
    "    output_dir = mount_drive()\n",
    "    create_sample_dataset()\n",
    "    model, tokenizer = load_model_and_tokenizer()\n",
    "    model = prepare_model_for_training(model)\n",
    "    train_dataset = prepare_dataset(tokenizer, \"sample_data.json\")\n",
    "    \n",
    "    training_args = TrainingArguments(\n",
    "        output_dir=output_dir,\n",
    "        num_train_epochs=1,\n",
    "        per_device_train_batch_size=2,\n",
    "        gradient_accumulation_steps=4,\n",
    "        learning_rate=1e-4,\n",
    "        fp16=True,\n",
    "        logging_steps=10,\n",
    "        save_steps=50,\n",
    "        warmup_steps=10,\n",
    "        save_total_limit=2,\n",
    "    )\n",
    "    \n",
    "    trainer = Trainer(\n",
    "        model=model,\n",
    "        args=training_args,\n",
    "        train_dataset=train_dataset,\n",
    "        data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),\n",
    "    )\n",
    "    \n",
    "    trainer.train()\n",
    "    trainer.save_model(os.path.join(output_dir, \"final_model\"))\n",
    "\n",
    "if __name__ == \"__main__\":\n",
    "    main()"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 4. 运行训练"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "!python train_colab.py"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## 5. 测试微调后的模型"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "from transformers import AutoModelForCausalLM, AutoTokenizer\n",
    "from peft import PeftModel\n",
    "\n",
    "def load_and_test_model():\n",
    "    base_model = AutoModelForCausalLM.from_pretrained(\n",
    "        \"deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B\",\n",
    "        trust_remote_code=True,\n",
    "        load_in_8bit=True,\n",
    "        device_map=\"auto\"\n",
    "    )\n",
    "    tokenizer = AutoTokenizer.from_pretrained(\n",
    "        \"deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B\",\n",
    "        trust_remote_code=True\n",
    "    )\n",
    "\n",
    "    model_path = \"/content/drive/MyDrive/model_training/final_model\"\n",
    "    model = PeftModel.from_pretrained(base_model, model_path)\n",
    "\n",
    "    def generate_response(prompt):\n",
    "        inputs = tokenizer(prompt, return_tensors=\"pt\").to(\"cuda\")\n",
    "        outputs = model.generate(**inputs, max_length=256, temperature=0.7)\n",
    "        return tokenizer.decode(outputs[0], skip_special_tokens=True)\n",
    "\n",
    "    test_prompt = \"解释什么是机器学习\"\n",
    "    response = generate_response(test_prompt)\n",
    "    print(f\"问题：{test_prompt}\")\n",
    "    print(f\"回答：{response}\")\n",
    "\n",
    "load_and_test_model()"
   ]
  }
 ],
 "metadata": {
  "accelerator": "GPU",
  "colab": {
   "name": "DeepSeek-R1-Distill-Qwen-1.5B 模型微调",
   "provenance": []
  },
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  },
  "language_info": {
   "codemirror_mode": {
    "name": "ipython",
    "version": 3
   },
   "file_extension": ".py",
   "mimetype": "text/x-python",
   "name": "python",
   "nbconvert_exporter": "python",
   "pygments_lexer": "ipython3",
   "version": "3.8.0"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 4
}
EOL

# 设置执行权限
chmod +x create_notebook.sh 