class_name PlanetMapCrosshair
extends Control

var point := Vector2.ZERO
var has_point := false
var content_rect := Rect2()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not UITheme.theme_changed.is_connected(_on_theme_changed):
		UITheme.theme_changed.connect(_on_theme_changed)


func _on_theme_changed(_theme_id: StringName) -> void:
	queue_redraw()

func set_point(value: Vector2) -> void:
	point = value
	has_point = true
	queue_redraw()

func clear_point() -> void:
	has_point = false
	queue_redraw()


func set_content_rect(value: Rect2) -> void:
	content_rect = value
	queue_redraw()


func _draw() -> void:
	if not has_point:
		return
	var line_color := UITheme.color(&"accent_bright")
	line_color.a = 0.9
	var draw_rect := content_rect
	if draw_rect.size.x <= 0.0 or draw_rect.size.y <= 0.0:
		draw_rect = Rect2(Vector2.ZERO, size)
	draw_line(
		Vector2(draw_rect.position.x, point.y),
		Vector2(draw_rect.end.x, point.y), line_color, 1.5
	)
	draw_line(
		Vector2(point.x, draw_rect.position.y),
		Vector2(point.x, draw_rect.end.y), line_color, 1.5
	)
	draw_circle(point, 4.0, line_color, false, 1.5)
