extends Node
## Repaint after WindowManager has established the native client size.
## Draw before the heavy main scene loads so an old-size boot buffer cannot linger.
func _ready() -> void:
	if DisplayServer.get_name() == "headless": return
	var background: Color = ProjectSettings.get_setting("application/boot_splash/bg_color", Color(0.54, 0.77, 0.87, 1.0))
	# Flush WM_SIZE before presenting: the native client changes before the
	# Vulkan swapchain receives the corresponding size notification.
	DisplayServer.process_events()
	RenderingServer.set_default_clear_color(background)
	RenderingServer.force_draw()
	var fill: Image = Image.create(1, 1, false, Image.FORMAT_RGB8)
	fill.fill(background)
	RenderingServer.set_boot_image(fill, background, true, false)
