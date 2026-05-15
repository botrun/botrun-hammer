# 多引擎 ASR 精準度報告

**生成時間**: 2026-05-15 12:00:08 CST
**音檔**: `reference_zh_25s.wav` (19.93s, 16kHz mono)
**Ground truth 字數**: 208

## 對照表

| 模型 | OK | CER (normalized) | CER (raw) | 載入秒 | 轉錄秒 | 即時率 |
|------|----|------------------|-----------|--------|--------|--------|
| `large-v3-turbo` | ✅ | **13.46%** | 30.77% | 0.3s | 0.94s | 0.05× |
| `large-v3` | ✅ | **12.98%** | 30.29% | 0.8s | 2.88s | 0.14× |
| `gemma-4-e4b` | ✅ | **15.87%** | 21.15% | 3.5s | 7.32s | 0.37× |

> **normalized**: 簡→繁 + 全形標點→半形 後算 CER（讓 Whisper 系列公平受比）。
> **raw**: 原始輸出直接比，含繁簡與標點差異懲罰。

## Ground Truth

```
大家好，這是波特槌語音轉文字的精準度測試。今天日期是二零二六年五月十五日，我們要驗證三個引擎的中文轉錄能力。第一個是 Whisper large v3，第二個是 large v3 turbo，第三個是 Google Gemma 4 E4B。請特別注意專有名詞，例如：台北一零一、行政院、財團法人國家實驗研究院、以及 MLX Apple Silicon 加速框架。混合英文像是 GitHub、 OpenAI、 token、 transcribe 也要正確。
```


## 各引擎輸出


### `large-v3-turbo`
```
大家好,这是波克锤语音转文字的精准度测试,今天日期是2026年5月15日,我们要验证三个引擎的中文转录能力,第一个是Whisper Large V3,第二个是Large V3 Turbo,第三个是Google Gemma 414B,请特别注意专有名词,例如,台北101,行政院,财团法人国家实验研究院,以及MLX Apple Silicon加速框架,混合英文像是GitHub,OpenEye,Token,Transcribe也要正确。
```

### `large-v3`
```
大家好,这是波特锤语音转文字的精准度测试,今天日期是2026年5月15日,我们要验证三个引擎的中文转录能力,第一个是Whisper Large V3,第二个是Large V3 Turbo,第三个是Google Drama 414B,请特别注意专有名词,例如,台北101,行政院,财团法人国家实验研究院,以及MLX Apple Silicon加速框架,混合英文像是GitHub,OpenAI,Token,Transcribe也要正确。
```

### `gemma-4-e4b`
```
大家好,這是波特傳語音轉文字的精準度測試,今天日期是2026年5月15日,我們要驗證三個引擎的中文轉錄能力,第一個是Whisper Large V3,第二個是Large V Central,第三個是Google Gemini 414B,請特別注意專有名詞,例如台北101,行政院,財團法人國家實驗研究院,以及MLX Apple Silicon加速框架,混和英文像是GitHub,OpenAI,Token,Transcribe也要正確。
```
