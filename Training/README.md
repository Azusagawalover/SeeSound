> 历史归档：自 0.12 起已取消 SNN 功能，当前 App 不运行或导入这里的模型。这些脚本、参数和真实实验记录保留用于复现旧版研究。当前环境声音使用 Resources/YAMNet.mlpackage。

# 见声声音实验

这里在电脑上用 snnTorch 训练一个小型 SNN，同时训练结构相近的 ANN；手机只读取 JSON 参数并推理，不内嵌 Python。
当前是探索性声音分类实验，不会替换 App 的系统声音识别、生成正式提醒或自动修改人工标签。

## 默认使用公开声音：无需自己采集

0.7 的 App 已随包提供 ESC-50 三类子集模型及全部 24 段留出录音，可以直接离线运行。实验范围和实际结果见 [公开声音实验说明](../docs/PublicSoundExperiment.md)。

如需从头复现，在本目录执行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python prepare_esc50.py --destination data/esc50
.venv/bin/python train_esc50.py --data data/esc50 --output output/esc50 --epochs 80
.venv/bin/python package_esc50.py --data data/esc50 --build output/esc50 --project ..
.venv/bin/python -m unittest discover -s . -p 'test_*.py'
```

准备步骤直接从官方仓库固定提交取得 120 段 WAV、CSV 与原始署名文件，不下载完整约 2000 段数据。训练固定使用官方 folds 1–4，fold 5 测试；不使用私人样本，也不上传文件。下载缓存位于 `data/`，训练产物位于 `output/`，都已排除 Git 跟踪。
打包步骤复制 24 段测试音频、模型、特征、许可及来源记录到项目资源；不会根据模型是否判断正确挑示例。电脑报告在 `Results/ESC50-Report.json`。
公开模型用 16 频带 Mel 特征与 32 路差分输入；以下个人样本方案仍使用原来的 4 特征 / 8 路输入，模型格式有明确区分。

## 可选：从自己的样本开始

1. 在 App「声音样本」录制或导入 0.5–5 秒音频，试听后确认标签。支持敲门、门铃、拍手、其他 / 背景，最多 100 段。
2. 每类至少 6 段、至少分布于 2 个独立采集批次。建议按不同房间、距离和时段采集，多于最低数量；更换条件后再点「开始新的采集批次」。批次是用户提供的分组，不代表软件能验证环境真的变化。
3. 导出「SeeSound-Dataset.json」。导出包含特征、标签、批次、样本 ID 和录音内容哈希；不包含原音频和备注。不自动联网。
4. 建立 Python 环境、安装依赖，运行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python train_sound.py /path/to/SeeSound-Dataset.json --output output/experiment.json --epochs 50
```

命令在本目录执行；将数据路径换成实际文件。代码兼容 Python 3.9–3.12，本轮实测 Python 3.12、PyTorch 2.5.1、snnTorch 0.9.4、NumPy 1.26.4，CPU 训练，不要求 CUDA。
本轮 Python 3.12 环境的完整依赖快照另存为 `requirements-lock-py312.txt`。
训练只读取导出的特征文件，不下载数据集、不上传音频。依赖安装本身需要联网。

5. 把 `output/experiment.json` 传到 iPhone / iPad 的「文件」App，在「SNN 实验室 → 模型」中导入。保留旁边的 `.report.json`，其中记录确切样本划分、随机种子、版本和文件哈希。

## 实验约定

- 音频先转换为单声道 16 kHz；整个片段时间归一为 64 帧，每帧提取 log-RMS、峰值、过零比例和平均相邻差值。强度是归一化特征，不是校准声压或分贝计。
- 以 0.08 为步长进行确定性的有符号差分编码，4 种特征各有上升 / 下降通道，共 8 路。每帧每特征最多一个脉冲，参考值逐步移动；Python 与 Swift 使用相同约定。
- SNN 为 8 → 24 LIF → 类别线性读出，时间平均得到 logits。采用 snnTorch Leaky、减阈值复位、reset_delay=False。ANN 为 8 → 24 ReLU → 类别线性读出，同样时间平均。
- 两者使用同一编码、同一训练 / 测试划分、相同轮数和优化器设置。这里只比较给定编码下的两种小网络，不代表已找到最好的普通音频方法。
- 按整个采集批次划分，训练和测试批次不能交叉，每边均需包含全部已选类别。划分仅依赖随机种子和分组标签，不按测试准确率挑选。没有有效划分时拒绝训练，不悄悄退回按片段随机划分。
- 训练不按测试集选择检查点。固定轮数后计算一次留出集准确率和混淆矩阵；没有从脉冲数量推算能耗。
- 导出的模型含一个编码后的数值自检输入及 Python 输出。App 校验维度、有限数值、批次分离、矩阵统计一致性，再检查 Swift 输出是否与 Python 相符。这个自检不能证明来源可信或标签正确。
- 手机显示的留出集报告来自导入文件，会明确标注未在手机重评；单个样本运行显示人工标签、所属批次及两种模型意见，不改变原标签。

## 无真实数据时检查工具链

```bash
.venv/bin/python train_sound.py --smoke --epochs 8 --output output/synthetic.json
.venv/bin/python -m unittest discover -s . -p 'test_*.py'
```

`--smoke` 生成带显式 `synthetic-smoke` 标记的数学特征，验证训练、导出和推理流程。合成数据的准确率不代表敲门、门铃或真人环境表现；App 会保留该标记。它不会添加到用户的声音样本库，也不会默认作为正式模型启用。
本轮生成的模型与神经元 trace 作为 `Checks/Fixtures` 下的测试夹具保留，不进入 App 资源。

## 开源代码与后续候选

| 项目 | 本轮用途 | 许可 |
| --- | --- | --- |
| [snnTorch 0.9.4](https://github.com/jeshraghian/snntorch/tree/v0.9.4) | 实际训练依赖；Leaky 对应方程在 Swift 重写，并做数值对照 | MIT |
| [SpikingJelly](https://github.com/fangwei123456/spikingjelly) | 可扩展的 SNN / ANN2SNN 与事件数据框架，本轮未引入 | 当前主分支 Apache-2.0，具体版本另核对 |
| [Tonic](https://github.com/neuromorphs/tonic) | 事件数据集与变换，适合后续独立研究，本轮未引入 | 当前主分支 GPL-3.0 |

snnTorch 固定提交为 `f5cb74654bc274736165dd2cd7455144c95588d4`，上游 Leaky 源文件和 MIT 许可在 `References/SNN/`；手机完整许可页面也包含声明。
神经形态语音数据集适合先学音频 SNN 的方法，但不能直接证明门铃 / 敲门等类别识别有效。后续应扩大真实环境样本、增加更完整的频谱特征与普通音频基线，并在设备上测量延迟、内存与实际能耗。
