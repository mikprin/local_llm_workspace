#!/usr/bin/env python3
"""Оценка VRAM под LLM. Пример: ./vram.py 14 --ctx 32768 --quant q4_k_m"""
import argparse

BPW = {"fp16":16,"q8_0":8.5,"q6_k":6.6,"q5_k_m":5.7,"q4_k_m":4.8,
       "q4_0":4.5,"q3_k_m":3.9,"iq2_xs":2.4}

p = argparse.ArgumentParser()
p.add_argument("params", type=float, help="млрд параметров (всего, для MoE тоже всего)")
p.add_argument("--quant", default="q4_k_m", choices=BPW)
p.add_argument("--ctx", type=int, default=32768, help="длина контекста (число токенов)")
p.add_argument("--layers", type=int, default=48)
p.add_argument("--kv-heads", type=int, default=8, help="KV-головы (GQA), не attention-головы")
p.add_argument("--head-dim", type=int, default=128)
p.add_argument("--kv-quant", default="q8_0", choices=["fp16","q8_0","q4_0"])
p.add_argument("--budget", type=float, default=14.5, help="доступно ГБ VRAM")
a = p.parse_args()

weights = a.params * BPW[a.quant] / 8
kv_bytes = {"fp16":2,"q8_0":1,"q4_0":0.5}[a.kv_quant]
kv = 2 * a.layers * a.kv_heads * a.head_dim * a.ctx * kv_bytes / 1024**3
overhead = 0.7
total = weights + kv + overhead

print(f"веса   ({a.quant:7}) : {weights:6.2f} ГБ")
print(f"KV-кэш ({a.kv_quant}, {a.ctx//1024}k): {kv:6.2f} ГБ")
print(f"оверхед            : {overhead:6.2f} ГБ")
print(f"{'-'*32}\nитого              : {total:6.2f} ГБ / бюджет {a.budget} ГБ")
print("✅ влезает" if total <= a.budget else
      f"❌ не влезает, не хватает {total-a.budget:.1f} ГБ (offload на CPU)")
