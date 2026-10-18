@tool
extends Marker2D
## 标记原点仍是出生位置；激活区域相对该出生姿势的脚底设置。

const DEFAULT_ACTIVATION_SIZE := Vector2(120.0, 32.0)

@export var activation_size := DEFAULT_ACTIVATION_SIZE
@export var activation_offset := Vector2.ZERO
