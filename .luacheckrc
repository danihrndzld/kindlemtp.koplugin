std = "luajit"
max_line_length = 120
files["spec"] = { std = "+busted" }
-- Translated strings stay on one line so xgettext can extract them (631: line too long),
-- and event handlers keep `self` even when they do not use it.
files["kindlemtp.koplugin"] = { ignore = { "631" }, self = false, read_globals = { "G_reader_settings" } }
