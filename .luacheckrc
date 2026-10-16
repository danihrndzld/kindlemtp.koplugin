std = "luajit"
max_line_length = 120
files["spec"] = { std = "+busted" }
-- Same allowances as KOReader's own .luacheckrc: translated strings stay on one line for xgettext,
-- and event handlers keep `self` even when they do not use it.
files["kindlemtp.koplugin"] = { ignore = { "631" }, self = false, read_globals = { "G_reader_settings" } }
