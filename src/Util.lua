local Util = {}

function Util.deepCopy(tbl: {[any]: any}): {[any]: any}
	local copy = table.create(#tbl)
	for key, value in tbl do
		if typeof(value) == "table" then
			copy[key] = Util.deepCopy(value)
		else
			copy[key] = value
		end
	end
	return copy
end

return Util
