extends Node

func shorten_string(text: String) -> String:
	if text.length() <= 500 or not SharedConstants.shorten_output:
		return text
	return "%s...%s" % [text.substr(0, 50), text.substr(text.length() - 250, 250)]
