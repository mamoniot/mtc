--By Mami
data:extend({
	{
		type = "int-setting",
		name = "cybersyn-ticks-per-second",
		order = "aa",
		setting_type = "runtime-global",
		default_value = 30,
		minimum_value = 1,
		maximum_value = 60,
	},
	{
		type = "int-setting",
		name = "cybersyn-request-threshold",
		order = "ab",
		setting_type = "runtime-global",
		default_value = 2000000000,
		minimum_value = 1,
		maximum_value = 2147483647,
	},
	{
		type = "int-setting",
		name = "cybersyn-provide-threshold",
		order = "ac",
		setting_type = "runtime-global",
		default_value = 2000000000,
		minimum_value = 1,
		maximum_value = 2147483647,
	},
	{
		type = "int-setting",
		name = "cybersyn-network-flag",
		order = "ad",
		setting_type = "runtime-global",
		default_value = 1,
		minimum_value = -2147483648,
		maximum_value = 2147483647,
	},
})