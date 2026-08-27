extends Node

signal theme_changed(theme_id: StringName)

const SETTINGS_PATH := "user://ui_theme.cfg"
const SETTINGS_SECTION := "appearance"
const SETTINGS_KEY := "theme"
const DEFAULT_THEME: StringName = &"amber"

const THEME_ORDER: Array[StringName] = [&"amber", &"ocean", &"contrast"]
const THEME_NAMES := {
	&"amber": "Ambre",
	&"ocean": "Océan",
	&"contrast": "Contraste élevé",
}

const PALETTES := {
	&"amber": {
		"accent": Color(0.92549, 0.619608, 0.0, 1.0),
		"accent_bright": Color(1.0, 0.72, 0.04, 1.0),
		"background": Color(0.035, 0.045, 0.05, 1.0),
		"surface": Color(0.045, 0.055, 0.06, 1.0),
		"panel": Color(0.065, 0.078, 0.082, 0.98),
		"panel_alt": Color(0.09, 0.105, 0.11, 0.98),
		"border": Color(0.19, 0.23, 0.24, 1.0),
		"text": Color(0.78, 0.81, 0.82, 1.0),
		"text_bright": Color(0.92, 0.94, 0.94, 1.0),
		"muted": Color(0.39, 0.43, 0.44, 1.0),
		"field": Color(0.055, 0.065, 0.07, 1.0),
		"disabled": Color(0.05, 0.06, 0.065, 1.0),
		"progress_track": Color(0.11, 0.13, 0.14, 1.0),
		"map_background": Color(0.018, 0.023, 0.025, 1.0),
		"brand": Color(0.18, 0.2, 0.21, 1.0),
		"placeholder": Color(0.53, 0.57, 0.58, 1.0),
		"secondary_text": Color(0.58, 0.62, 0.63, 1.0),
		"selection": Color(0.42, 0.28, 0.0, 1.0),
		"success": Color(0.16, 0.75, 0.2, 1.0),
		"danger": Color(0.82, 0.18, 0.16, 1.0),
		"font_scale": 1.0,
	},
	&"ocean": {
		"accent": Color(0.30, 0.72, 0.82, 1.0),
		"accent_bright": Color(0.55, 0.91, 0.97, 1.0),
		"background": Color(0.025, 0.07, 0.085, 1.0),
		"surface": Color(0.04, 0.105, 0.125, 1.0),
		"panel": Color(0.055, 0.135, 0.16, 0.98),
		"panel_alt": Color(0.075, 0.18, 0.205, 0.98),
		"border": Color(0.16, 0.34, 0.38, 1.0),
		"text": Color(0.72, 0.83, 0.85, 1.0),
		"text_bright": Color(0.90, 0.98, 0.99, 1.0),
		"muted": Color(0.38, 0.55, 0.58, 1.0),
		"field": Color(0.035, 0.095, 0.115, 1.0),
		"disabled": Color(0.055, 0.12, 0.135, 1.0),
		"progress_track": Color(0.08, 0.19, 0.22, 1.0),
		"map_background": Color(0.01, 0.035, 0.045, 1.0),
		"brand": Color(0.13, 0.27, 0.30, 1.0),
		"placeholder": Color(0.46, 0.62, 0.65, 1.0),
		"secondary_text": Color(0.54, 0.69, 0.71, 1.0),
		"selection": Color(0.08, 0.30, 0.36, 1.0),
		"success": Color(0.25, 0.79, 0.55, 1.0),
		"danger": Color(0.96, 0.38, 0.38, 1.0),
		"font_scale": 1.0,
	},
	&"contrast": {
		"accent": Color(1.0, 0.82, 0.0, 1.0),
		"accent_bright": Color(1.0, 0.94, 0.36, 1.0),
		"background": Color(0.0, 0.0, 0.0, 1.0),
		"surface": Color(0.035, 0.035, 0.035, 1.0),
		"panel": Color(0.055, 0.055, 0.055, 1.0),
		"panel_alt": Color(0.085, 0.085, 0.085, 1.0),
		"border": Color(0.62, 0.62, 0.62, 1.0),
		"text": Color(0.92, 0.92, 0.92, 1.0),
		"text_bright": Color.WHITE,
		"muted": Color(0.68, 0.68, 0.68, 1.0),
		"field": Color(0.025, 0.025, 0.025, 1.0),
		"disabled": Color(0.10, 0.10, 0.10, 1.0),
		"progress_track": Color(0.16, 0.16, 0.16, 1.0),
		"map_background": Color.BLACK,
		"brand": Color(0.36, 0.36, 0.36, 1.0),
		"placeholder": Color(0.72, 0.72, 0.72, 1.0),
		"secondary_text": Color(0.78, 0.78, 0.78, 1.0),
		"selection": Color(0.36, 0.29, 0.0, 1.0),
		"success": Color(0.25, 1.0, 0.38, 1.0),
		"danger": Color(1.0, 0.32, 0.28, 1.0),
		"font_scale": 1.10,
	},
}

var current_theme_id: StringName = DEFAULT_THEME
var _icon_cache: Dictionary = {}


func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		var stored := StringName(str(config.get_value(SETTINGS_SECTION, SETTINGS_KEY, DEFAULT_THEME)))
		if PALETTES.has(stored):
			current_theme_id = stored


func get_theme_ids() -> Array[StringName]:
	return THEME_ORDER.duplicate()


func get_theme_name(theme_id: StringName) -> String:
	return str(THEME_NAMES.get(theme_id, theme_id))


func get_theme_index(theme_id: StringName = current_theme_id) -> int:
	return maxi(THEME_ORDER.find(theme_id), 0)


func color(role: StringName) -> Color:
	var palette: Dictionary = PALETTES[current_theme_id]
	return palette.get(str(role), Color.MAGENTA)


func font_scale() -> float:
	return float(PALETTES[current_theme_id].get("font_scale", 1.0))


func create_theme() -> Theme:
	var base := load("res://data/font/font.tres") as Theme
	var result := base.duplicate(true) as Theme if base != null else Theme.new()
	result.default_font_size = roundi(16.0 * font_scale())
	return result


func set_theme(theme_id: StringName, persist: bool = true) -> void:
	if not PALETTES.has(theme_id):
		push_warning("[UITheme] Unknown theme: %s" % theme_id)
		return
	if current_theme_id == theme_id:
		return
	current_theme_id = theme_id
	_icon_cache.clear()
	if persist:
		var config := ConfigFile.new()
		config.set_value(SETTINGS_SECTION, SETTINGS_KEY, str(theme_id))
		var error := config.save(SETTINGS_PATH)
		if error != OK:
			push_warning("[UITheme] Could not save appearance settings: %s" % error)
	theme_changed.emit(theme_id)


func apply_to_tree(root: Control) -> void:
	if root == null:
		return
	root.theme = create_theme()
	_apply_node(root)


func _apply_node(node: Node) -> void:
	_apply_theme_properties(node)
	if node is ColorRect:
		_apply_color_rect(node as ColorRect)
	if node is HSlider:
		_apply_slider_icons(node as HSlider)
	if node is SpinBox:
		_apply_spinbox_icon(node as SpinBox)
	if node is Button and node.name == &"RandomButton":
		_apply_random_button(node as Button)
	if node is OptionButton:
		var popup := (node as OptionButton).get_popup()
		_apply_theme_properties(popup)
		_apply_popup_icons(popup)
	for child in node.get_children(true):
		_apply_node(child)


func _apply_theme_properties(object: Object) -> void:
	var color_roles: Dictionary = object.get_meta(&"ui_theme_color_roles", {})
	var style_roles: Dictionary = object.get_meta(&"ui_theme_style_roles", {})
	var font_sizes: Dictionary = object.get_meta(&"ui_theme_font_sizes", {})
	for property in object.get_property_list():
		var property_name := str(property.get("name", ""))
		if property_name.begins_with("theme_override_colors/"):
			var value = object.get(property_name)
			if value is Color:
				if not color_roles.has(property_name):
					var role := _infer_role(value)
					if not role.is_empty():
						color_roles[property_name] = role
				if color_roles.has(property_name):
					object.set(property_name, color(StringName(color_roles[property_name])))
		elif property_name.begins_with("theme_override_styles/"):
			var style = object.get(property_name)
			if style is StyleBoxFlat or style is StyleBoxLine:
				if not style_roles.has(property_name):
					style_roles[property_name] = _capture_style_roles(style)
				object.set(property_name, _themed_style(style, style_roles[property_name]))
		elif property_name.begins_with("theme_override_font_sizes/"):
			var raw_size = object.get(property_name)
			if typeof(raw_size) != TYPE_INT and typeof(raw_size) != TYPE_FLOAT:
				continue
			var size := roundi(float(raw_size))
			if size > 0:
				if not font_sizes.has(property_name):
					font_sizes[property_name] = size
				object.set(property_name, maxi(1, roundi(float(font_sizes[property_name]) * font_scale())))
	object.set_meta(&"ui_theme_color_roles", color_roles)
	object.set_meta(&"ui_theme_style_roles", style_roles)
	object.set_meta(&"ui_theme_font_sizes", font_sizes)


func _capture_style_roles(style: Resource) -> Dictionary:
	if style is StyleBoxFlat:
		return {
			"background": _infer_role((style as StyleBoxFlat).bg_color),
			"border": _infer_role((style as StyleBoxFlat).border_color),
		}
	if style is StyleBoxLine:
		return {"line": _infer_role((style as StyleBoxLine).color)}
	return {}


func _themed_style(style: Resource, roles: Dictionary) -> Resource:
	var themed := style.duplicate(true)
	if themed is StyleBoxFlat:
		if not str(roles.get("background", "")).is_empty():
			(themed as StyleBoxFlat).bg_color = color(StringName(roles["background"]))
		if not str(roles.get("border", "")).is_empty():
			(themed as StyleBoxFlat).border_color = color(StringName(roles["border"]))
	elif themed is StyleBoxLine and not str(roles.get("line", "")).is_empty():
		(themed as StyleBoxLine).color = color(StringName(roles["line"]))
	return themed


func _apply_color_rect(rect: ColorRect) -> void:
	var role := str(rect.get_meta(&"ui_theme_color_rect_role", ""))
	if role.is_empty():
		role = _infer_role(rect.color)
		if not role.is_empty():
			rect.set_meta(&"ui_theme_color_rect_role", role)
	if not role.is_empty():
		rect.color = color(StringName(role))


func _infer_role(value: Color) -> String:
	var best_role := ""
	var best_distance := INF
	for theme_id in THEME_ORDER:
		var palette: Dictionary = PALETTES[theme_id]
		for key in palette:
			if key == "font_scale":
				continue
			var candidate: Color = palette[key]
			var distance := (
				pow(value.r - candidate.r, 2.0)
				+ pow(value.g - candidate.g, 2.0)
				+ pow(value.b - candidate.b, 2.0)
				+ pow(value.a - candidate.a, 2.0)
			)
			if distance < best_distance:
				best_distance = distance
				best_role = str(key)
	return best_role if best_distance <= 0.012 else ""


func _apply_slider_icons(slider: HSlider) -> void:
	slider.add_theme_icon_override("grabber", _make_grabber_icon(color(&"accent")))
	slider.add_theme_icon_override("grabber_highlight", _make_grabber_icon(color(&"accent_bright")))


func _apply_popup_icons(popup: PopupMenu) -> void:
	var normal := _make_grabber_icon(color(&"accent"))
	var checked := _make_grabber_icon(color(&"accent_bright"))
	popup.add_theme_icon_override("radio_unchecked", normal)
	popup.add_theme_icon_override("radio_checked", checked)
	popup.add_theme_icon_override("unchecked", normal)
	popup.add_theme_icon_override("checked", checked)


func _apply_spinbox_icon(spin: SpinBox) -> void:
	var icon := _make_spinbox_icon(color(&"accent_bright"))
	for icon_name in [&"updown", &"updown_hover", &"updown_pressed", &"updown_disabled"]:
		spin.add_theme_icon_override(icon_name, icon)


func _apply_random_button(button: Button) -> void:
	button.icon = _make_dice_icon()
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_color_override("icon_normal_color", color(&"accent"))
	button.add_theme_color_override("icon_hover_color", color(&"background"))
	button.add_theme_color_override("icon_pressed_color", color(&"background"))
	button.add_theme_color_override("icon_disabled_color", color(&"muted"))
	button.add_theme_stylebox_override("normal", _flat_style(color(&"field"), color(&"accent"), 2))
	button.add_theme_stylebox_override("hover", _flat_style(color(&"accent_bright"), color(&"accent_bright"), 2))
	button.add_theme_stylebox_override("pressed", _flat_style(color(&"accent"), color(&"accent"), 2))
	button.add_theme_stylebox_override("disabled", _flat_style(color(&"disabled"), color(&"border"), 1))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _flat_style(background_color: Color, border_color: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background_color
	style.border_color = border_color
	style.set_border_width_all(border_width)
	style.set_content_margin_all(4.0)
	return style


func _make_grabber_icon(icon_color: Color) -> Texture2D:
	var key := "grabber_%s" % icon_color.to_html()
	if _icon_cache.has(key):
		return _icon_cache[key]
	var image := Image.create(17, 17, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(17):
		for x in range(17):
			if abs(x - 8) + abs(y - 8) <= 7:
				image.set_pixel(x, y, icon_color)
	var texture := ImageTexture.create_from_image(image)
	_icon_cache[key] = texture
	return texture


func _make_spinbox_icon(icon_color: Color) -> Texture2D:
	var key := "spin_%s" % icon_color.to_html()
	if _icon_cache.has(key):
		return _icon_cache[key]
	var image := Image.create(14, 30, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(4):
		for x in range(7 - y, 7 + y + 1):
			image.set_pixel(x, 9 - y, icon_color)
			image.set_pixel(x, 20 + y, icon_color)
	var texture := ImageTexture.create_from_image(image)
	_icon_cache[key] = texture
	return texture


func _make_dice_icon() -> Texture2D:
	const KEY := "dice_white"
	if _icon_cache.has(KEY):
		return _icon_cache[KEY]
	var image := Image.create(22, 22, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(3, 19):
		for x in range(3, 19):
			if x in [3, 4, 17, 18] or y in [3, 4, 17, 18]:
				image.set_pixel(x, y, Color.WHITE)
	for center in [Vector2i(7, 7), Vector2i(14, 7), Vector2i(10, 11), Vector2i(7, 15), Vector2i(14, 15)]:
		for y in range(center.y - 1, center.y + 1):
			for x in range(center.x - 1, center.x + 1):
				image.set_pixel(x, y, Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	_icon_cache[KEY] = texture
	return texture
