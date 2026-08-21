# 内参模型对照、鱼眼可逆域与检测距离

本文把容易混淆的 `AttemptN` 改成“相机 + 标定板状态 + 点集处理”的可读名称。
旧编号只保留在“证据来源”中，用于追溯文件，不能再把编号当成相机编号。

特别说明：`images\docs\attempt11_cam0_calibration_audit` 是后来复制进来的 cam0 审计目录，
其目录名与旧清单里的 cam1 Attempt11 重名，但二者不是同一模型。下表以 JSON 实际
`camera_id`、`K`、`dist_coeffs` 和 `quality.rms_px` 为准。

## 1. K、D 与训练 RMS

所有模型均为 OpenCV fisheye，图像为 640×480，系数顺序为
`(k1, k2, k3, k4)`。

| 可读名称 | 点集处理 | f_x | f_y | c_x | c_y | k_1 | k_2 | k_3 | k_4 | RMS (px) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| CAM0 (Polluted Calibration) | 全44点，未移除污染点 | 980.696 | 980.494 | 331.733 | 237.125 | -0.067619 | -1.223901 | 6.313766 | -2.241874 | 0.575699 |
| CAM0 (Polluted Calibration) | 移除索引26 | 902.815 | 900.353 | 333.160 | 254.579 | -0.085984 | 1.258922 | -17.177113 | 59.428212 | 0.473022 |
| CAM0 (Non-polluted Calibration) | 全44点；当前保留模型 | 945.302 | 940.266 | 296.432 | 243.254 | -0.064566 | -0.635570 | 10.800304 | -50.872060 | 0.419823 |
| CAM1 (Polluted Calibration) | 全44点，未移除污染点 | 458.154 | 456.879 | 326.514 | 227.061 | 0.294955 | 1.941089 | -5.898360 | 5.961477 | 0.575167 |
| CAM1 (Polluted Calibration) | 移除索引26；旧 cam1 发布模型 | 440.629 | 440.922 | 320.366 | 227.923 | 0.341351 | 1.387749 | -3.484777 | 2.631246 | 0.359865 |
| CAM1 (Non-polluted Calibration) | 全44点基础数据 | 495.852 | 496.576 | 323.709 | 236.820 | 0.379515 | 1.418522 | -1.521428 | -4.257476 | 0.426624 |
| CAM1 (Non-polluted Calibration) | 全44点 + 边角补充 | 454.642 | 454.366 | 321.284 | 233.959 | 0.340850 | 1.344358 | -2.021791 | -1.039116 | 0.286566 |

证据来源依次为：

- CAM0 污染板、全44点：`images\docs\attempt11_cam0_calibration_audit\cam0_intrinsics.json`
- CAM0 污染板、移除26：`build\attempt10_cam0_calibration_audit_mask26\cam0_intrinsics_mask26.json`
- CAM0 非污染板：`build\attempt12_cam0_calibration_audit_full44\cam0_intrinsics_full44.json`
- CAM1 污染板、全44点：`build\attempt9_calibration_audit\cam1_intrinsics.json`
- CAM1 污染板、移除26：`build\attempt11_cam1_calibration_audit_mask26\cam1_intrinsics_mask26.json`
- CAM1 非污染板基础/边角：`build\attempt13_cam1_calibration_audit_full44` 与
  `build\attempt14_cam1_calibration_audit_full44_corner`

因此，过去所说的“CAM1 A11 两层”需要作一个证据修正：现存的“未移除”结果 JSON
来自旧全44点模型，而移除索引26的 JSON 才来自旧 Attempt11。两层都列在表中，
但不把旧全44点数值伪装成同一目录产生的第二个模型。

## 2. 平均值、标准差和 CV

统计按物理相机分别计算：CAM0 使用上表3个历史模型，CAM1 使用4个旧相机模型。
这里是已列出总体的总体标准差（`ddof=0`），CV 定义为
`标准差 / abs(平均值) × 100%`。

| Camera | Statistic | f_x | f_y | c_x | c_y | k_1 | k_2 | k_3 | k_4 | RMS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| CAM0 (n=3) | Mean | 942.937 | 940.371 | 320.442 | 244.986 | -0.072723 | -0.200183 | -0.021014 | 2.104759 | 0.489514 |
| CAM0 (n=3) | Std. dev. | 31.839 | 32.718 | 16.987 | 7.230 | 0.009459 | 1.059331 | 12.268688 | 45.134668 | 0.064696 |
| CAM0 (n=3) | CV | 3.38% | 3.48% | 5.30% | 2.95% | 13.01% | 529.18% | 58,382.26% | 2,144.41% | 13.22% |
| CAM1 (n=4) | Mean | 462.319 | 462.186 | 322.968 | 231.441 | 0.339168 | 1.522929 | -3.231589 | 0.824033 | 0.412056 |
| CAM1 (n=4) | Std. dev. | 20.440 | 20.761 | 2.384 | 4.088 | 0.029959 | 0.242858 | 1.700297 | 3.839024 | 0.106406 |
| CAM1 (n=4) | CV | 4.42% | 4.49% | 0.74% | 1.77% | 8.83% | 15.95% | 52.61% | 465.88% | 25.82% |

`k2–k4` 的 CV 不能像焦距 CV 一样解释。高阶系数会互相补偿并跨零，CAM0 的
`k3` 平均值接近零，所以 58,382% 主要是除数接近零造成的，并不等于单独一个
可解释的“误差百分比”。判断模型应看整条径向映射、独立 holdout 和数值可逆域，
不能只比较单个高阶系数或训练 RMS。

## 3. 水平 FOV 对照

下表严格复现原表采用的近似：`FOV_approx = (640 / f_x) × 180 / pi`。
它是等距鱼眼的一阶估算，不含主点偏移，也没有反解 `k1–k4`，所以不是镜头标签
或完整标定模型的真实边到边 FOV。

| Camera / calibration | f_x | Estimated horizontal FOV | Nominal label |
|---|---:|---:|---:|
| CAM0 (Polluted, full44) | 980.696 | 37.4° | 120° |
| CAM0 (Polluted, point26 removed) | 902.815 | 40.6° | 120° |
| CAM0 (Non-polluted) | 945.302 | 38.8° | 120° |
| CAM1 (Polluted, full44) | 458.154 | 80.0° | 160°（旧 cam1） |
| CAM1 (Polluted, point26 removed) | 440.629 | 83.2° | 160°（旧 cam1） |
| CAM1 (Non-polluted, full44) | 495.852 | 74.0° | 160°（旧 cam1） |
| CAM1 (Non-polluted, corner supplement) | 454.642 | 80.7° | 160°（旧 cam1） |
| CAM1 (replacement) | 待新内参 | 待计算 | 120°（当前硬件） |

120°/160°是镜头名义标签；标定得到的是镜头、传感器有效面积、裁切和安装共同作用后的
成像映射。尤其是当前更换后的120° cam1，不能沿用旧160° cam1 的 440.629 px 或
83.2°。完成新 cam1 内参后必须从新 JSON 重新填写。

## 4. fisheye polynomial 在整张图像上的可逆性

OpenCV fisheye 使用：

```text
theta_d = theta * (1 + k1*theta^2 + k2*theta^4 + k3*theta^6 + k4*theta^8)
d(theta_d)/d(theta)
        = 1 + 3*k1*theta^2 + 5*k2*theta^4 + 7*k3*theta^6 + 9*k4*theta^8
```

只有从光轴到 640×480 最远角点所需的整个角度区间内导数保持正值，且角点的
畸变半径没有超过第一个单调分支，整张图的径向反解才是一对一。检查结果如下；
“89.9°内未转折”不代表多项式对任意更大角度都全局可逆，只代表已覆盖当前传感器域。

| Calibration | Full-frame radial inverse | Corner theta | First turn / checked limit | Margin | Holdout / decision |
|---|---|---:|---:|---:|---|
| CAM0 (Polluted, full44) | Pass | 24.409° | 81.946° | 57.537° | V1 P95/max 1.240/1.486 px；V2 2.000/3.154 px；拒绝 |
| CAM0 (Polluted, point26 removed) | Pass | 26.715° | 89.9°内未转折 | 63.185° | 缺少当前发布格式的独立固定 K/D 证据；拒绝 |
| CAM0 (Non-polluted) | Pass with warning | 26.796° | 29.128° | 2.332° | V1、V2 通过；当前保留 cam0 |
| CAM1 (Polluted, full44) | Pass | 40.638° | 89.9°内未转折 | 49.262° | P95/max 1.202/1.533 px；拒绝 |
| CAM1 (Polluted, point26 removed) | Pass | 41.928° | 89.9°内未转折 | 47.972° | 干净板完整44点 V1、V2 通过；旧 cam1 发布模型 |
| CAM1 (Non-polluted, full44) | **Fail at corners** | 无安全反解 | 39.616° | 无 | V1/V2 max 22,157/21,368 px；拒绝 |
| CAM1 (Non-polluted, corner supplement) | **Fail at corners** | 无安全反解 | 43.736° | 无 | V1/V2 max 7,111/6,849 px；拒绝 |

反馈可以概括为：CAM0 非污染模型在图像内仍可逆，但角点外只剩约2.33°余量，
所以标定板不要压到四角；CAM1 移除索引26的旧模型拥有很大的单调余量，并已用
干净板完整44点独立验证。CAM1 两个非污染训练模型虽然训练 RMS 分别只有
0.427 px 和 0.287 px，却在角点进入非单调分支并在 holdout 爆炸，证明“更低训练
RMS”不等于“更好的鱼眼模型”。当前新120° cam1 尚无 K/D，因此目前没有任何
依据宣称其整幅图可逆；新内参流程必须重新执行相同域检查。

## 5. Practical detection range

标定板圆点直径为10 mm。下表使用中心区域的一阶尺度
`p ~= f_x * 10 / Z`：把6 px 作为理论检测下限，则
`Z_max ~= f_x * 10 / 6`；把15 px 作为较稳健尺寸，则
`Z_15 ~= f_x * 10 / 15`。

| Camera / calibration | f_x | Maximum detectable distance (6 px) | Approx. distance at 15 px |
|---|---:|---:|---:|
| CAM0 (Polluted, full44) | 980.696 | 1,634 mm | 654 mm |
| CAM0 (Polluted, point26 removed) | 902.815 | 1,505 mm | 602 mm |
| CAM0 (Non-polluted) | 945.302 | 1,576 mm | 630 mm |
| CAM1 (Polluted, full44) | 458.154 | 764 mm | 305 mm |
| CAM1 (Polluted, point26 removed) | 440.629 | 734 mm | 294 mm |
| CAM1 (Non-polluted, full44) | 495.852 | 826 mm | 331 mm |
| CAM1 (Non-polluted, corner supplement) | 454.642 | 758 mm | 303 mm |
| CAM1 (replacement) | 待新内参 | 待计算 | 待计算 |

这些数值是圆点中心附近、近似正视条件下的尺度估计，不是整块标定板的保证距离：

- 倾角会让圆点短轴近似乘以 `cos(tilt)`；45°时可用距离约再降29%。
- 板的完整4×11点阵也必须全部落入两台相机的共同视野，近距离下通常先受“板放不下”
  限制，远距离下才受圆点像素直径限制。
- 鱼眼边缘局部尺度与中心不同；不可逆的 CAM1 非污染候选即使能算出本表距离，也不能发布。
- 对旧组合，15 px 的共同上限由 CAM1 决定，约294 mm，但这个距离下 CAM0 未必能装下
  完整长边。正式双目采集应从约450–550 mm开始，以实时完整44点、边缘余量和圆点短轴
  为准，而不是机械地追求15 px。
- 对当前双120°组合，应在新 cam1 内参完成后用
  `min(fx_cam0, fx_new_cam1) * 10 / threshold_px` 重算共同上限。22 mm基线和约3°夹角
  影响共同视野与深度几何，但不应被写进这个单圆点尺度公式，也不应作为内/外参求解的强制先验。
