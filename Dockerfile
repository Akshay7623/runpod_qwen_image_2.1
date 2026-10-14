
# Qwen-Image-2.1 (uncensored, FP8): text to image and image editing
# ComfyUI on RunPod Serverless
# All model weights baked into the image.

ARG BASE_IMAGE=nvidia/cuda:13.0.3-base-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=v0.39.0
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=2.14.1
ARG TORCHVISION_VERSION=0.29.1

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_INPUT=1
ENV PIP_NO_CACHE_DIR=1
ENV UV_NO_CACHE=1

# Make the system C/C++ compilers available to Triton.
ENV CC=/usr/bin/gcc
ENV CXX=/usr/bin/g++

# Install Python, compilers, and system dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && gcc --version \
    && g++ --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install uv and create the Python virtual environment.
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv --python /usr/bin/python3.12 /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# Triton compiles against Python.h on the worker; fail the build if gcc cannot find it.
RUN echo '#include <Python.h>' | gcc -fsyntax-only -x c \
    -I"$(python -c 'import sysconfig; print(sysconfig.get_paths()["include"])')" -

# Install pinned ComfyUI release.
RUN git clone --depth 1 --branch "${COMFYUI_VERSION}" \
    https://github.com/Comfy-Org/ComfyUI.git /comfyui

# Install CUDA 13.0 PyTorch first.
RUN uv pip install \
    "torch==${TORCH_VERSION}" \
    "torchvision==${TORCHVISION_VERSION}" \
    --index-url "${PYTORCH_INDEX_URL}"

# Install ComfyUI and worker dependencies.
RUN uv pip install \
    -r /comfyui/requirements.txt \
    "transformers>=4.50.3,<5" \
    "huggingface-hub<1.0" \
    runpod==1.7.13 \
    requests==2.32.4 \
    websocket-client==1.8.0 \
    boto3==1.40.21

# Verify Python dependencies and ComfyUI startup.
RUN cd /comfyui && timeout 300 \
    python main.py --quick-test-for-ci --cpu

# All weights come from abenzerps' uncensored repo, pinned to a commit so the
# content cannot change. Declared here, not at the top, so the layers above
# stay cached when it moves.
ARG UC_REPO=https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-Quantized/resolve/7959e658915f52274897fb573ffeda49de8dc16b

# Download the Qwen-Image-2.1 uncensored FP8 diffusion model.
RUN set -e; \
    fetch() { \
      mkdir -p "/comfyui/models/$1"; \
      wget -nv --tries=5 \
        -O "/comfyui/models/$1/$2" \
        "$3"; \
    }; \
    fetch diffusion_models qwen-image-2.1-UC-fp8.safetensors "${UC_REPO}/qwen-image-2.1-UC-fp8.safetensors"

# Download the text encoder (Qwen3-VL 8B, BF16) and the VAE.
RUN set -e; \
    fetch() { \
      mkdir -p "/comfyui/models/$1"; \
      wget -nv --tries=5 \
        -O "/comfyui/models/$1/$2" \
        "$3"; \
    }; \
    fetch text_encoders qwen3vl_8b_bf16.safetensors "${UC_REPO}/text_encoders/qwen3vl_8b_bf16.safetensors" & p1=$!; \
    fetch vae qwen_image_2.1_vae_bf16.safetensors "${UC_REPO}/vae/qwen_image_2.1_vae_bf16.safetensors" & p2=$!; \
    wait "$p1"; \
    wait "$p2"

WORKDIR /

# Add the RunPod handler and startup script.
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

CMD ["/start.sh"]
