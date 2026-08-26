class_name PlanetMapCrosshair
extends Control

var point := Vector2.ZERO
var has_point := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_point(value: Vector2) -> void:
	point = value
	has_point = true
	queue_redraw()

func clear_point() -> void:
	has_point = false
	queue_redraw()

func _draw() -> void:
	if not has_point:
		return
	var line_color := Color(1.0, 0.62, 0.04, 0.9)
	draw_line(Vector2(0.0, point.y), Vector2(size.x, point.y), line_color, 1.5)
	draw_line(Vector2(point.x, 0.0), Vector2(point.x, size.y), line_color, 1.5)
	draw_circle(point, 4.0, line_color, false, 1.5)
