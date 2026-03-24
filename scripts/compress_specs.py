#!/usr/bin/env python3
"""
Compress markdown files in specs directory using LLMLingua and create
a mirrored directory with .txt files containing compressed content.
"""

import os
import re
import shutil
import sys
from pathlib import Path

from llmlingua import PromptCompressor

# ==================== CONFIGURATION ====================
SOURCE_DIR = "specs"
TARGET_DIR = "specs_llm"
MODEL_NAME = "microsoft/llmlingua-2-xlm-roberta-large-meetingbank"
COMPRESSION_RATE = 0.5
USE_LLMLINGUA2 = True
PROTECT_CODE_BLOCKS = True
# ========================================================


def main():
    source_path = Path(SOURCE_DIR)
    target_path = Path(TARGET_DIR)

    # Validate source exists
    if not source_path.exists():
        print(f"Error: Source directory '{SOURCE_DIR}' does not exist")
        sys.exit(1)

    # Clean and recreate target directory
    if target_path.exists():
        shutil.rmtree(target_path)
        print(f"Removed existing '{TARGET_DIR}' directory")
    target_path.mkdir(parents=True)
    print(f"Created '{TARGET_DIR}' directory")

    # Initialize compressor
    print(f"Initializing LLMLingua with model: {MODEL_NAME}")
    try:
        llm_lingua = PromptCompressor(
            model_name=MODEL_NAME,
            use_llmlingua2=USE_LLMLINGUA2,
        )
    except Exception as e:
        print(f"Failed to initialize LLMLingua: {e}")
        sys.exit(1)

    # Statistics
    total_files = 0
    successful = 0
    failed = 0

    # Walk through source directory
    for root, dirs, files in os.walk(source_path):
        for filename in files:
            if not filename.endswith(".md"):
                continue

            total_files += 1
            source_file = Path(root) / filename

            # Compute relative path and target path
            rel_path = source_file.relative_to(source_path)
            target_file = target_path / rel_path.with_suffix(".txt")

            # Create parent directories
            target_file.parent.mkdir(parents=True, exist_ok=True)

            # Read, compress, write
            try:
                with open(source_file, "r", encoding="utf-8") as f:
                    content = f.read()

                if PROTECT_CODE_BLOCKS:
                    # Split by code blocks to keep them intact
                    pattern = r"(```[\s\S]*?```)"
                    parts = re.split(pattern, content)
                    compressed_parts = []

                    for part in parts:
                        if part.startswith("```"):
                            # Preserve code blocks/diagrams exactly
                            compressed_parts.append(part)
                        elif len(part.strip()) > 20:
                            # Compress prose segments that have significant content
                            res = llm_lingua.compress_prompt(
                                part, rate=COMPRESSION_RATE
                            )
                            compressed_parts.append(res["compressed_prompt"])
                        else:
                            # Keep very short snippets or whitespace as is
                            compressed_parts.append(part)

                    compressed = "".join(compressed_parts)
                else:
                    result = llm_lingua.compress_prompt(content, rate=COMPRESSION_RATE)
                    compressed = result["compressed_prompt"]

                with open(target_file, "w", encoding="utf-8") as f:
                    f.write(compressed)

                print(f"✓ {rel_path} -> {rel_path.with_suffix('.txt')}")
                successful += 1
            except Exception as e:
                print(f"✗ {rel_path} - {type(e).__name__}: {e}")
                failed += 1

    # Summary
    print("\n" + "=" * 50)
    print(f"Summary: Total={total_files}, Successful={successful}, Failed={failed}")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
