class_name ParameterWorkspace
extends CanvasLayer

signal generate_requested
signal save_planet_requested
signal load_preset_requested
signal save_preset_requested
signal viewer_requested
signal quit_requested
signal language_requested(code: String)

const UI_AMBER := Color(0.92549, 0.619608, 0.0, 1.0)
const UI_AMBER_BRIGHT := Color(1.0, 0.72, 0.04, 1.0)
const UI_DARK := Color(0.035, 0.045, 0.05, 1.0)
const UI_PANEL := Color(0.065, 0.078, 0.082, 0.98)
const UI_PANEL_ALT := Color(0.09, 0.105, 0.11, 0.98)
const UI_BORDER := Color(0.19, 0.23, 0.24, 1.0)
const UI_TEXT := Color(0.78, 0.81, 0.82, 1.0)
const UI_MUTED := Color(0.39, 0.43, 0.44, 1.0)
const PARAMETER_SCHEMA := preload("res://src/scenes/planet_parameter_schema.gd")

var root: Control
var title_label: Label
var preview_title_label: Label
var parameter_title_label: Label
var preview_panel: PanelContainer
var preview_texture: TextureRect
var preview_empty_label: Label
var parameters_host: PanelContainer
var viewer_button: Button
var load_preset_button: Button
var save_preset_button: Button
var quit_button: Button
var french_button: Button
var english_button: Button
var german_button: Button
var generate_button: Button
var random_button: Button
var save_planet_button: Button

var _parameter_tree: VBoxContainer
var _controls: Dictionary = {}
var _value_labels: Dictionary = {}
var _category_buttons: Dictionary = {}
var _category_bodies: Dictionary = {}
var _option_definitions: Dictionary = {}


func _ready() -> void:
	layer = 40
	_build_interface()
	_build_parameters_from_schema()
	_connect_actions()
	refresh_translations()
	get_viewport().size_changed.connect(_layout_interface)
	_layout_interface()


func _panel_style(
	background: Color = UI_PANEL,
	border: Color = UI_BORDER,
	border_width: int = 1,
	content_margin: float = 10.0
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.content_margin_left = content_margin
	style.content_margin_top = content_margin
	style.content_margin_right = content_margin
	style.content_margin_bottom = content_margin
	return style


func style_button(button: Button, compact: bool = false, primary: bool = false) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(90 if compact else 185, 34 if compact else 46)
	button.add_theme_color_override("font_color", UI_DARK if primary else UI_AMBER)
	button.add_theme_color_override("font_hover_color", UI_DARK)
	button.add_theme_color_override("font_pressed_color", UI_DARK)
	button.add_theme_color_override("font_disabled_color", UI_MUTED)
	button.add_theme_font_size_override("font_size", 17 if compact else 22)
	var normal_background := UI_AMBER if primary else Color(0.04, 0.05, 0.055, 1.0)
	button.add_theme_stylebox_override("normal", _panel_style(normal_background, UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("hover", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 2, 4.0))
	button.add_theme_stylebox_override("pressed", _panel_style(UI_AMBER, UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.065, 1.0), UI_BORDER, 1, 4.0))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_line_edit(edit: LineEdit) -> void:
	edit.add_theme_color_override("font_color", UI_TEXT)
	edit.add_theme_font_size_override("font_size", 18)
	var style := load("res://data/styles/lineEdit.tres") as StyleBox
	if style != null:
		edit.add_theme_stylebox_override("normal", style)
	edit.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_option(option: OptionButton) -> void:
	option.focus_mode = Control.FOCUS_NONE
	option.custom_minimum_size.y = 34
	option.add_theme_color_override("font_color", UI_TEXT)
	option.add_theme_color_override("font_hover_color", UI_AMBER_BRIGHT)
	option.add_theme_font_size_override("font_size", 18)
	var field_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 1, 6.0)
	for style_name in ["normal", "normal_mirrored", "pressed", "pressed_mirrored", "hover", "hover_mirrored", "hover_pressed", "hover_pressed_mirrored", "disabled", "disabled_mirrored"]:
		option.add_theme_stylebox_override(style_name, field_style)
	option.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_slider(slider: HSlider) -> void:
	slider.custom_minimum_size.y = 25
	slider.add_theme_icon_override("grabber", load("res://data/img/UI/Range/Grabber.png"))
	slider.add_theme_icon_override("grabber_highlight", load("res://data/img/UI/Range/Grabber_grabbed.png"))
	slider.add_theme_stylebox_override("slider", load("res://data/styles/slider_non_highlight.tres"))
	slider.add_theme_stylebox_override("grabber_area", load("res://data/styles/slider_highlight.tres"))


func _build_interface() -> void:
	root = Control.new()
	root.name = "ParameterWorkspace"
	root.theme = load("res://data/font/font.tres")
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = UI_DARK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var header := PanelContainer.new()
	header.name = "Header"
	header.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 10.0))
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header.add_child(header_row)
	title_label = Label.new()
	title_label.text = "PLANET GENERATOR"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_color_override("font_color", UI_AMBER)
	title_label.add_theme_font_size_override("font_size", 32)
	header_row.add_child(title_label)
	load_preset_button = Button.new()
	style_button(load_preset_button, true)
	header_row.add_child(load_preset_button)
	save_preset_button = Button.new()
	style_button(save_preset_button, true)
	header_row.add_child(save_preset_button)
	viewer_button = Button.new()
	style_button(viewer_button, true)
	header_row.add_child(viewer_button)
	french_button = Button.new()
	french_button.text = "FR"
	style_button(french_button, true)
	french_button.custom_minimum_size.x = 52
	header_row.add_child(french_button)
	english_button = Button.new()
	english_button.text = "EN"
	style_button(english_button, true)
	english_button.custom_minimum_size.x = 52
	header_row.add_child(english_button)
	german_button = Button.new()
	german_button.text = "DE"
	style_button(german_button, true)
	german_button.custom_minimum_size.x = 52
	header_row.add_child(german_button)
	quit_button = Button.new()
	style_button(quit_button, true)
	header_row.add_child(quit_button)

	preview_panel = PanelContainer.new()
	preview_panel.name = "PreviewPanel"
	var preview_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 2.0)
	preview_style.content_margin_top = 38.0
	preview_panel.add_theme_stylebox_override("panel", preview_style)
	preview_panel.clip_contents = true
	root.add_child(preview_panel)
	preview_texture = TextureRect.new()
	preview_texture.name = "PreviewTexture"
	preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_panel.add_child(preview_texture)
	preview_empty_label = Label.new()
	preview_empty_label.name = "PreviewEmptyState"
	preview_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview_empty_label.add_theme_color_override("font_color", UI_MUTED)
	preview_empty_label.add_theme_font_size_override("font_size", 24)
	preview_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_panel.add_child(preview_empty_label)
	preview_title_label = Label.new()
	preview_title_label.name = "PreviewTitle"
	preview_title_label.add_theme_color_override("font_color", UI_AMBER)
	preview_title_label.add_theme_font_size_override("font_size", 20)
	preview_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(preview_title_label)

	parameters_host = PanelContainer.new()
	parameters_host.name = "ParametersHost"
	var parameter_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 8.0)
	parameter_style.content_margin_top = 42.0
	parameters_host.add_theme_stylebox_override("panel", parameter_style)
	root.add_child(parameters_host)
	parameter_title_label = Label.new()
	parameter_title_label.name = "ParameterTitle"
	parameter_title_label.add_theme_color_override("font_color", UI_AMBER)
	parameter_title_label.add_theme_font_size_override("font_size", 22)
	parameter_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(parameter_title_label)

	var actions := PanelContainer.new()
	actions.name = "Actions"
	actions.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 10.0))
	root.add_child(actions)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 12)
	actions.add_child(action_row)
	generate_button = Button.new()
	generate_button.name = "GenerateButton"
	style_button(generate_button, false, true)
	action_row.add_child(generate_button)
	random_button = Button.new()
	random_button.name = "RandomButton"
	style_button(random_button)
	action_row.add_child(random_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(spacer)
	save_planet_button = Button.new()
	save_planet_button.name = "SavePlanetButton"
	style_button(save_planet_button)
	action_row.add_child(save_planet_button)


func _build_parameters_from_schema() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "ParameterScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parameters_host.add_child(scroll)
	_parameter_tree = VBoxContainer.new()
	_parameter_tree.name = "ParameterTree"
	_parameter_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_parameter_tree.add_theme_constant_override("separation", 8)
	scroll.add_child(_parameter_tree)

	for category in PARAMETER_SCHEMA.CATEGORY_ORDER:
		_create_category(str(category))
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		_create_parameter(definition)


func _create_category(category: String) -> void:
	var panel := PanelContainer.new()
	panel.name = category.capitalize() + "Category"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(UI_PANEL_ALT, UI_BORDER, 1, 6.0))
	_parameter_tree.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var header := Button.new()
	header.name = "Header"
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	style_button(header, true)
	header.custom_minimum_size = Vector2(0, 32)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(header)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 8)
	box.add_child(body)
	header.pressed.connect(func() -> void:
		body.visible = not body.visible
	)
	_category_buttons[category] = header
	_category_bodies[category] = body


func _create_parameter(definition: Dictionary) -> void:
	var key := str(definition["key"])
	var category := str(definition["category"])
	var body := _category_bodies.get(category) as VBoxContainer
	if body == null:
		push_error("[ParameterWorkspace] Missing category: " + category)
		return
	var row := VBoxContainer.new()
	row.name = key
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 3)
	body.add_child(row)

	var label := Label.new()
	label.name = "Label"
	label.add_theme_color_override("font_color", UI_TEXT)
	label.add_theme_font_size_override("font_size", 16)
	row.add_child(label)
	_value_labels[key] = label

	var kind := str(definition.get("kind", "slider"))
	match kind:
		"text":
			var hbox := HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 6)
			row.add_child(hbox)
			var edit := LineEdit.new()
			edit.name = "Value"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text = str(definition.get("default", ""))
			_style_line_edit(edit)
			hbox.add_child(edit)
			var random_name_button := Button.new()
			random_name_button.text = "↻"
			random_name_button.tooltip_text = "Random name"
			style_button(random_name_button, true)
			random_name_button.custom_minimum_size = Vector2(42, 32)
			random_name_button.pressed.connect(randomize_name)
			hbox.add_child(random_name_button)
			_controls[key] = edit
		"spinbox":
			var hbox := HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 6)
			row.add_child(hbox)
			var spin := SpinBox.new()
			spin.name = "Value"
			spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spin.min_value = float(definition.get("min", 0.0))
			spin.max_value = float(definition.get("max", 100.0))
			spin.step = float(definition.get("step", 1.0))
			spin.value = float(definition.get("default", 0.0))
			hbox.add_child(spin)
			var random_seed_button := Button.new()
			random_seed_button.text = "↻"
			random_seed_button.tooltip_text = "Random seed"
			style_button(random_seed_button, true)
			random_seed_button.custom_minimum_size = Vector2(42, 32)
			random_seed_button.pressed.connect(randomize_seed)
			hbox.add_child(random_seed_button)
			_controls[key] = spin
		"option":
			var option := OptionButton.new()
			option.name = "Value"
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_style_option(option)
			var options: Array = definition.get("options", [])
			for option_definition in options:
				option.add_item(str(option_definition[0]), int(option_definition[1]))
			option.select(_option_index_for_id(option, int(definition.get("default", 0))))
			row.add_child(option)
			_controls[key] = option
			_option_definitions[key] = options
		_:
			var slider := HSlider.new()
			slider.name = "Value"
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.min_value = float(definition.get("min", 0.0))
			slider.max_value = float(definition.get("max", 100.0))
			slider.step = float(definition.get("step", 1.0))
			slider.value = float(definition.get("default", 0.0))
			_style_slider(slider)
			row.add_child(slider)
			_controls[key] = slider
			slider.value_changed.connect(func(_value: float) -> void:
				_refresh_parameter_label(key)
			)

	_refresh_parameter_label(key)


func _connect_actions() -> void:
	generate_button.pressed.connect(func() -> void: generate_requested.emit())
	random_button.pressed.connect(randomize_parameters)
	save_planet_button.pressed.connect(func() -> void: save_planet_requested.emit())
	load_preset_button.pressed.connect(func() -> void: load_preset_requested.emit())
	save_preset_button.pressed.connect(func() -> void: save_preset_requested.emit())
	viewer_button.pressed.connect(func() -> void: viewer_requested.emit())
	quit_button.pressed.connect(func() -> void: quit_requested.emit())
	french_button.pressed.connect(func() -> void: language_requested.emit("fr"))
	english_button.pressed.connect(func() -> void: language_requested.emit("en"))
	german_button.pressed.connect(func() -> void: language_requested.emit("de"))


func _layout_interface() -> void:
	if root == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := 22.0
	var header_height := 70.0
	var body_top := margin + header_height + 14.0
	var action_height := 70.0
	var action_top := viewport_size.y - action_height - margin
	var body_height := action_top - body_top - 10.0
	var right_width := clampf(viewport_size.x * 0.34, 430.0, 500.0)
	var gap := 12.0
	var left_width := viewport_size.x - margin * 2.0 - right_width - gap
	var header := root.get_node("Header") as Control
	header.position = Vector2(margin, margin)
	header.size = Vector2(viewport_size.x - margin * 2.0, header_height)
	preview_panel.position = Vector2(margin, body_top)
	preview_panel.size = Vector2(left_width, body_height)
	preview_title_label.position = Vector2(margin + 12.0, body_top + 8.0)
	preview_title_label.size = Vector2(left_width - 24.0, 26.0)
	parameters_host.position = Vector2(margin + left_width + gap, body_top)
	parameters_host.size = Vector2(right_width, body_height)
	parameter_title_label.position = Vector2(parameters_host.position.x + 14.0, body_top + 8.0)
	parameter_title_label.size = Vector2(right_width - 28.0, 28.0)
	var actions := root.get_node("Actions") as Control
	actions.position = Vector2(margin, action_top)
	actions.size = Vector2(viewport_size.x - margin * 2.0, action_height)


func set_preview_texture(texture: Texture2D) -> void:
	preview_texture.texture = texture
	preview_texture.visible = texture != null
	preview_empty_label.visible = texture == null


func get_value(key: String) -> Variant:
	var control: Control = _controls.get(key) as Control
	if control == null:
		push_error("[ParameterWorkspace] Unknown parameter: " + key)
		return null
	if control is LineEdit:
		return (control as LineEdit).text
	if control is OptionButton:
		return (control as OptionButton).get_selected_id()
	if control is Range:
		return (control as Range).value
	return null


func set_value(key: String, value: Variant) -> bool:
	var control: Control = _controls.get(key) as Control
	if control == null:
		return false
	if control is LineEdit:
		(control as LineEdit).text = str(value)
	elif control is OptionButton:
		var option := control as OptionButton
		option.select(_option_index_for_id(option, int(value)))
	elif control is Range:
		(control as Range).value = float(value)
	else:
		return false
	_refresh_parameter_label(key)
	return true


func get_values() -> Dictionary:
	var values: Dictionary = {}
	for key in PARAMETER_SCHEMA.keys():
		values[key] = get_value(key)
	return values


func apply_values(values: Dictionary) -> void:
	for key in PARAMETER_SCHEMA.keys():
		if values.has(key):
			set_value(key, values[key])
	refresh_translations()


func randomize_parameters() -> void:
	randomize()
	randomize_name()
	randomize_seed()
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		var key := str(definition["key"])
		if key in ["planet_name", "seed"] or not bool(definition.get("randomize", true)):
			continue
		var control: Control = _controls.get(key) as Control
		if control is HSlider:
			var slider := control as HSlider
			var steps := maxi(int(round((slider.max_value - slider.min_value) / slider.step)), 0)
			var random_step := randi_range(0, steps)
			slider.value = slider.min_value + float(random_step) * slider.step
		elif control is OptionButton:
			var option := control as OptionButton
			if option.item_count > 0:
				option.select(randi_range(0, option.item_count - 1))
	refresh_translations()


func randomize_seed() -> void:
	set_value("seed", randi())


func randomize_name() -> void:
	var prefixes: Array[String] = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", "Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", "Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega", "Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra", "Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes: Array[String] = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]
	var generated_name: String = prefixes[randi_range(0, prefixes.size() - 1)] + "-" + str(randi_range(1, 999))
	if randf() > 0.5:
		generated_name += " " + suffixes[randi_range(0, suffixes.size() - 1)]
	set_value("planet_name", generated_name)


func refresh_translations() -> void:
	if root == null:
		return
	preview_title_label.text = tr("VIEWER_PREVIEW")
	parameter_title_label.text = tr("PARAMETRES")
	preview_empty_label.text = "%s\n%s" % [tr("VIEWER_EMPTY_TITLE"), tr("VIEWER_EMPTY_HINT")]
	load_preset_button.text = tr("LOAD_PRESET")
	save_preset_button.text = tr("SAVE_PRESET")
	viewer_button.text = tr("MAP_VIEWER_TITLE").to_upper()
	quit_button.text = tr("LEAVE")
	generate_button.text = tr("GENERER")
	random_button.text = tr("RANDOMISE")
	save_planet_button.text = tr("SAUVEGARDER")

	for category in PARAMETER_SCHEMA.CATEGORY_ORDER:
		var category_key := str(category)
		var button := _category_buttons.get(category_key) as Button
		if button != null:
			button.text = tr(str(PARAMETER_SCHEMA.CATEGORY_LABELS[category_key])).to_upper()
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		var key := str(definition["key"])
		_refresh_parameter_label(key)
		if str(definition.get("kind", "slider")) == "option":
			_refresh_option_items(key)


func set_actions_enabled(enabled: bool) -> void:
	generate_button.disabled = not enabled
	random_button.disabled = not enabled
	load_preset_button.disabled = not enabled
	save_preset_button.disabled = not enabled
	viewer_button.disabled = not enabled


func set_save_planet_enabled(enabled: bool) -> void:
	save_planet_button.disabled = not enabled


func _refresh_parameter_label(key: String) -> void:
	var label := _value_labels.get(key) as Label
	if label == null:
		return
	var definition := PARAMETER_SCHEMA.definition(key)
	if definition.is_empty():
		return
	var tr_key := str(definition.get("label", key))
	var kind := str(definition.get("kind", "slider"))
	if kind in ["text", "option", "spinbox"]:
		label.text = tr(tr_key)
		return
	var value := float(get_value(key))
	var unit := str(definition.get("unit", ""))
	var formatted_value := _format_number(value, float(definition.get("step", 1.0))) + unit
	var translated := tr(tr_key)
	label.text = translated.format({"val": formatted_value})


func _refresh_option_items(key: String) -> void:
	var option := _controls.get(key) as OptionButton
	if option == null:
		return
	var selected_id := option.get_selected_id()
	var options: Array = _option_definitions.get(key, [])
	option.clear()
	for option_definition in options:
		option.add_item(tr(str(option_definition[0])), int(option_definition[1]))
	option.select(_option_index_for_id(option, selected_id))


func _option_index_for_id(option: OptionButton, id: int) -> int:
	for index in range(option.item_count):
		if option.get_item_id(index) == id:
			return index
	return 0


func _format_number(value: float, step: float) -> String:
	if step >= 1.0:
		return str(int(round(value))) if is_equal_approx(value, round(value)) else String.num(value, 2)
	var decimals := clampi(int(ceil(-log(step) / log(10.0))), 1, 6)
	return String.num(value, decimals)
