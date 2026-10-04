extends Node
# 直接持有像素形状，供 PixelBody2D.collect_shapes() 读取

const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

var shape: PixelShape = null

func get_shape() -> PixelShape:
	return shape if shape != null else PixelShape.new()
