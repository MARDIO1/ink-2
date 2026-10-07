@tool
class_name InkUIResource
extends Resource

@export_group("Colors")
@export var background: Color = Color("#0b0e13")
@export var panel: Color = Color("#121720")
@export var panel_raised: Color = Color("#181f2b")
@export var border: Color = Color("#2b3545")
@export var text: Color = Color("#eef3fa")
@export var text_muted: Color = Color("#8e9aac")
@export var accent: Color = Color("#79e6c1")
@export var accent_pressed: Color = Color("#47b996")
@export var danger: Color = Color("#ff7c82")
@export var selection: Color = Color("#ffb45d")

@export_group("Typography")
@export_range(8, 48, 1) var body_font_size: int = 16
@export_range(8, 64, 1) var title_font_size: int = 24
@export_range(8, 32, 1) var caption_font_size: int = 12

@export_group("Geometry")
@export_range(0, 32, 1) var corner_radius: int = 8
@export_range(0, 64, 1) var spacing_small: int = 8
@export_range(0, 96, 1) var spacing_medium: int = 16
@export_range(0, 128, 1) var spacing_large: int = 24
@export_range(24, 96, 1) var control_height: int = 44

