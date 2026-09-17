extends Node

## Nothing to do with the plugin — exists purely so there is something to set a
## breakpoint on when testing the DAP half of the setup.


func _ready() -> void:
	var total := 0
	for i in range(5):
		total += _double(i)
		print("step %d -> %d" % [i, total])
	print("total = %d" % total)
	get_tree().quit()


func _double(value: int) -> int:
	return value * 2
