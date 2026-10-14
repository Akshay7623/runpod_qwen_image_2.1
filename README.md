# Qwen-Image-2.1 Uncensored on RunPod Serverless

[abenzerps/Qwen-Image-2.1-Uncensored-Quantized](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-Quantized) (FP8) running in ComfyUI as a RunPod serverless worker. It generates images from text and edits images from an instruction, with up to 16 reference images.

All model files are baked into the Docker image, so the endpoint needs no network volume and no Hugging Face token.

> **License:** abenzerps' repo is published under the Qwen Research License, which allows research and evaluation only. Serving it in a product needs a separate commercial license from Qwen. See [License](#license).

## What is in the image

| Part | File | Size |
| --- | --- | --- |
| Diffusion model (uncensored, FP8) | `qwen-image-2.1-UC-fp8.safetensors` | 7.1 GB |
| Text encoder (Qwen3-VL 8B, BF16) | `qwen3vl_8b_bf16.safetensors` | 17.5 GB |
| VAE | `qwen_image_2.1_vae_bf16.safetensors` | 0.7 GB |

The models total 25.3 GB.

The image also has ComfyUI v0.39.0 and PyTorch 2.14.1 built for CUDA 13.0.

### Where the weights come from

All three files come from [abenzerps/Qwen-Image-2.1-Uncensored-Quantized](https://huggingface.co/abenzerps/Qwen-Image-2.1-Uncensored-Quantized), pinned to commit `7959e65`. That repo says its uncensored files were built from Qwen/Qwen-Image-2.1 with comfy-kitchen and have no safety checker or content filter.

- **Diffusion model:** the repo's `SHA256SUMS` file does not list the FP8 file. The SHA-256 that Hugging Face records for it is `877b77290339986bca8f771aead381c7a5777347c27d252bbaa915f76667ab0b`.
- **Text encoder and VAE:** these match `SHA256SUMS`, and are byte-identical to Comfy-Org's official copies in [Comfy-Org/Qwen-Image-2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1).

Checks on the FP8 file so far, done by reading its header without downloading it:

- It is in ComfyUI's own per-layer FP8 format, with 229 FP8 layers.
- ComfyUI v0.39.0's model detection reads it as Qwen-Image-2.1 with the same configuration as the official BF16 file: 32 layers and hidden size 4096.
- It stores each MLP's gate and up projections as separate weights, where the official file stores them fused. ComfyUI v0.39.0 accepts both layouts.

It has not yet been loaded or run on a GPU.

If abenzerps' repo is ever deleted, rebuilds fail until `UC_REPO` in the Dockerfile points somewhere else. Images that are already built keep working.

## Deploy

RunPod builds the image from this repo; nothing is built locally.

1. In the RunPod console, go to **Serverless → New Endpoint → Import Git Repository** and pick this repo, branch `main`, Dockerfile path `Dockerfile`.
2. Set the endpoint options below.
3. Deploy. To rebuild after a change, publish a new GitHub release.

| Setting | Value | Why |
| --- | --- | --- |
| Allowed CUDA Versions | `13.0` | The image's PyTorch needs NVIDIA driver 580 or newer. On an older host the worker exits at startup. |
| GPU | 48 GB | The diffusion model (7.1 GB) and the text encoder (17.5 GB) then both stay in VRAM between jobs. On 24 GB and 32 GB cards, ComfyUI should move the text encoder in and out of VRAM instead, but that has not been tried. |
| Execution timeout | 600 s (the default) to start | A 1024x1024 image is much shorter work than video, but the first job on a cold worker also loads 25 GB of models. Raise it if 2K images or large edits time out. |
| Max workers | 1 while testing | |

FP8 runs natively on Ada, Hopper and Blackwell cards (L40S, RTX 4090, H100, RTX 5090). Older cards such as the A6000, A40 and A100 should also run it, since ComfyUI converts FP8 weights on the fly, but more slowly.

Environment variables:

| Variable | Needed | Purpose |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Yes | S3 upload and Lambda callbacks |
| `BUCKET_NAME` | Yes, unless every request sends `data.bucketName` | Bucket for the output image |
| `AWS_REGION` | No, defaults to `ap-south-1` | |

RunPod's GitHub builds are limited to an 80 GB image, 160 minutes in total, and 30 minutes for the `docker build` step. Download speeds vary a lot between builds, so if one times out, start it again. If it keeps timing out while downloading models, build the image elsewhere and push it to a registry.

## Request

The request format is the same as the LTX-2.5, MiniMax H3 and Wan endpoints: a ComfyUI API-format graph in `input.workflow`, optional input images, and an optional `data` block for the backend callbacks.

```json
{
  "input": {
    "workflow": { },
    "images": [{ "name": "input.png", "image": "<base64>" }],
    "data": {
      "workflowId": "...",
      "generationId": "...",
      "bucketName": "...",
      "triggerFunc": "...",
      "failureFunc": "..."
    }
  }
}
```

Three ready-made requests are in the repo:

- [test_input.json](test_input.json): text to image, 1024x1024, 25 steps, short prompt. For a first test.
- [sample-req-t2i.json](sample-req-t2i.json): text to image, 1024x1024, with the prompt from ComfyUI's template.
- [sample-req-edit.json](sample-req-edit.json): image edit, output about 1 megapixel. Replace `<BASE64_IMAGE>` with a real image.

The same two sample graphs are also in [workflow-t2i.json](workflow-t2i.json) and [workflow-edit.json](workflow-edit.json) on their own, without the request wrapper. Each is the value to send as `input.workflow`.

The output is a PNG. It is uploaded to `outputs/{workflowId}/{generationId}.png`, or to `images/{uuid}.png` when the request has no `data` block. The job returns `{"status": "success", "s3_url": "...", "job_id": "..."}`. Only the first image is uploaded, so keep `batch_size` at 1.

The graphs are ComfyUI's published Qwen-Image-2.1 graphs (`image_qwen_image_2_1_t2i` and `image_qwen_image_2_1_image_edit`) in API format, with these changes besides the model filenames and the values below:

- **The prompt enhancer is removed.** The templates include an optional Qwen 3.5 9B model that rewrites the prompt first. It is off by default in both templates and would add 9.5 GB to the image. Its `PreviewAny` node was a second output node; with two outputs, ComfyUI accepts a request whose image branch failed validation and reports success with no image.
- **Text to image:** `ResolutionSelector` rounds to a multiple of 32 instead of 8, so the size it picks is the size you get. See [Resolution](#resolution).
- **Image edit:** `resolution` is 1024 instead of 0. With 0, the output keeps the uploaded image's own size, so a 4000x3000 photo would be generated at full size. 1024 is the official default.
- **Image edit:** the graph takes one input image instead of two, and the template's custom-size switch is removed. The output follows the input image's aspect ratio.

### What to change in the graph

| Setting | Text to image | Image edit | Input | Meaning |
| --- | --- | --- | --- | --- |
| Prompt | `459:452` | `459:474` | `prompt` | What to generate, or the edit instruction. In edits, refer to input images as `<image1>`, `<image2>` and so on. |
| Negative prompt | `459:452` | `459:474` | `negative_prompt` | Only used when `cfg` is above 1. |
| Aspect ratio | `13` | | `aspect_ratio` | One of `1:1 (Square)`, `16:9 (Widescreen)`, `9:16 (Portrait Widescreen)`, `4:3 (Standard)`, `3:4 (Portrait Standard)`, `3:2 (Photo)`, `2:3 (Portrait Photo)`, `21:9 (Ultrawide)`. |
| Size | `13` | | `megapixels` | See [Resolution](#resolution). |
| Edit size | | `459:474` | `resolution` | A pixel budget: the output is about `resolution × resolution` pixels, with the first image's aspect ratio, rounded to multiples of 32. Up to 2048. `0` keeps the input image's own size. |
| Steps | `459:458` | `459:458` | `steps` | 25, as in ComfyUI's templates. The official pipeline uses 40 to 50 with `euler`. |
| CFG | `459:458` | `459:458` | `cfg` | Keep at 1. Raise it only together with a negative prompt; above 1, each step does about twice the work. |
| Seed | `459:458` | `459:458` | `seed` | Seed. |
| Input image | | `470` | `image` | The name of the uploaded image to edit. |

### More reference images in an edit

`image_1` is the image being edited, and further images are references for it, for example a garment to put on the person in `image_1`. To add one:

1. Upload it in `input.images` under a new name, such as `ref.png`.
2. Add a `LoadImage` node for it: `"471": {"inputs": {"image": "ref.png"}, "class_type": "LoadImage"}`.
3. On node `459:474`, add `"images.image_2": ["471", 0]`. Further images go in `images.image_3` and so on, up to `images.image_16`.

Each reference image is resized to about `resolution × resolution` pixels and adds work to every step, so many large references make the job slower.

### Transparent images

ComfyUI's notes give this prompt form for an image with a transparent background:

```
This is an RGBA format image with transparency. <your description>. The image has an alpha channel and a transparent background.
```

The graphs save PNG, which keeps the alpha channel.

### Resolution

Output sizes with `multiple: 32`:

| `aspect_ratio` | `megapixels: 1` | `2` | `4` |
| --- | --- | --- | --- |
| `1:1 (Square)` | 1024x1024 | 1440x1440 | 2048x2048 |
| `16:9 (Widescreen)` | 1376x768 | 1920x1088 | 2720x1536 |
| `9:16 (Portrait Widescreen)` | 768x1376 | 1088x1920 | 1536x2720 |
| `4:3 (Standard)` | 1184x896 | 1664x1248 | 2368x1760 |
| `3:2 (Photo)` | 1248x832 | 1760x1184 | 2496x1664 |
| `21:9 (Ultrawide)` | 1568x672 | 2208x960 | 3136x1344 |

According to ComfyUI's notes, the model supports 2048x2048 natively. At 4 megapixels, every aspect ratio except 1:1 has a side longer than 2048, and none of these sizes has been run on this worker yet.

## License

abenzerps' repo lists its license as `qwen-research`, the [Qwen Research License Agreement](https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE). Its files are derived from Qwen-Image-2.1, and the license carries over to them. Read it before putting this in front of users. The parts that affect a deployment:

- **It allows research and evaluation only.** Any commercial use, including running it behind a product, needs a separate commercial license, requested from Qwen at model-business@notice.qwencloud.com.
- If you distribute the built image, for example on a public registry, include a copy of the license and a notice file containing: "Qwen is licensed under the Qwen RESEARCH LICENSE AGREEMENT, Copyright (c) 2026 Hangzhou Tongyi Laboratory Technology Co., Ltd. All Rights Reserved."
- A product built on it may not use "Qwen" as its primary name.
- Disputes fall under Chinese law and the courts of Hangzhou.

The diffusion model has no content filter. What the endpoint generates is the operator's responsibility, under RunPod's terms and the law where it is used.

The worker code is based on [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui) and is under the AGPL-3.0 ([LICENSE](LICENSE)).
