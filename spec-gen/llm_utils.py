import os
import re
import time
from pathlib import Path

import torch
from loguru import logger
from peft import PeftModel
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
)

BASE_MODEL = "Qwen/Qwen2.5-Coder-7B-Instruct"
ADAPTER_PATH = Path(__file__).parent.parent / "lora-adapter"
MAX_NEW_TOKENS = 4096
# The adapter was trained QLoRA-style, so a 4-bit NF4 base matches training
# and fits the 7B model in ~5 GB of VRAM. KERNELGPT_4BIT=0 loads full precision.
LOAD_IN_4BIT = os.environ.get("KERNELGPT_4BIT", "1") == "1"

system_message = (
    "You are Syzkaller specification generator and "
    "linux kernel source code analyzer."
    "You only reply with JSON."
)

_tokenizer = None
_model = None


def load_model():
    """Load the base model with the LoRA adapter once and cache it."""
    global _tokenizer, _model
    if _model is None:
        logger.info(f"Loading {BASE_MODEL} with adapter {ADAPTER_PATH}")
        _tokenizer = AutoTokenizer.from_pretrained(ADAPTER_PATH)
        quantization = None
        if LOAD_IN_4BIT:
            quantization = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_quant_type="nf4",
                bnb_4bit_compute_dtype=torch.bfloat16,
            )
        base_model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL,
            dtype="auto",
            device_map="auto",
            quantization_config=quantization,
        )
        _model = PeftModel.from_pretrained(base_model, ADAPTER_PATH)
        _model.eval()
    return _tokenizer, _model


def extract_json(text: str):
    """Strip a markdown code fence if the model wrapped its JSON in one."""
    match = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    return match.group(1).strip() if match else text.strip()


def query_llm(prompt: str, temperature=0.1):
    tokenizer, model = load_model()
    messages = [
        {"role": "system", "content": system_message},
        {"role": "user", "content": prompt},
    ]
    try:
        logger.info(f"Invoke LLM with max_new_tokens={MAX_NEW_TOKENS}")
        t_start = time.time()
        inputs = tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            return_tensors="pt",
            return_dict=True,
        ).to(model.device)
        with torch.no_grad():
            output = model.generate(
                **inputs,
                max_new_tokens=MAX_NEW_TOKENS,
                do_sample=True,
                temperature=temperature,
            )
        g_time = time.time() - t_start
        logger.info(f"LLM response time: {g_time}")
    except Exception as e:
        logger.error(f"Exception: {e}, skip this prompt")
        return None
    prompt_len = inputs["input_ids"].shape[1]
    answer = tokenizer.decode(output[0][prompt_len:], skip_special_tokens=True)
    return extract_json(answer)
