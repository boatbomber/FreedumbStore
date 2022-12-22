--[=[

	module:Sanitize()
	takes a table and returns a encoding compatible copy

	module:Desanitize()
	takes a sanitized table and returns a normalized copy

	Currently supported datatypes:

	primitives (string, number, bool)
	Axes,BrickColor,CFrame,Color3,ColorSequence,DateTime,
	EnumItem,Faces,Instance,NumberRange,NumberSequence,		(Instance saves the path and deserializes with best effort)
	PhysicalProperties,Ray,Rect,UDim,UDim2,Vector2,Vector3

	Currently unsupported datatypes:
	(These aren't Properties so they aren't needed for now)

	CatalogSearchParams,ColorSequenceKeypoint,
	DockWidgetPluginGuiInfo,NumberSequenceKeypoint,
	PathWaypoint,Random,RaycastParams,RaycastResult,
	RBXScriptConnection,RBXScriptSignal,Region3,
	Region3int16,TweenInfo,Vector2int16,Vector3int16
--]=]

local module = {}

local TypeHandlers = {
	["Axes"] = {
		Sanitize = function(input: Axes)
			return {
				__sanitize = "Axes",
				Top = input.Top,
				Bottom = input.Bottom,
				Left = input.Left,
				Right = input.Right,
				Back = input.Back,
				Front = input.Front,
			}
		end,
		Desanitize = function(input)
			return Axes.new(
				input.Top and Enum.NormalId.Top or nil,
				input.Bottom and Enum.NormalId.Bottom or nil,
				input.Left and Enum.NormalId.Left or nil,
				input.Right and Enum.NormalId.Right or nil,
				input.Back and Enum.NormalId.Back or nil,
				input.Front and Enum.NormalId.Front or nil
			)
		end,
	},
	["BrickColor"] = {
		Sanitize = function(input: BrickColor)
			return {
				__sanitize = "BrickColor",
				R = math.round(input.Color.R * 255),
				G = math.round(input.Color.G * 255),
				B = math.round(input.Color.B * 255),
			}
		end,
		Desanitize = function(input)
			return BrickColor.new(Color3.fromRGB(input.R, input.G, input.B))
		end,
	},
	["CFrame"] = {
		Sanitize = function(input: CFrame)
			return {
				__sanitize = "CFrame",
				components = table.pack(input:GetComponents()),
			}
		end,
		Desanitize = function(input)
			return CFrame.new(table.unpack(input.components))
		end,
	},
	["Color3"] = {
		Sanitize = function(input: Color3)
			return {
				__sanitize = "Color3",
				R = math.round(input.R * 255),
				G = math.round(input.G * 255),
				B = math.round(input.B * 255),
			}
		end,
		Desanitize = function(input)
			return Color3.fromRGB(input.R, input.G, input.B)
		end,
	},
	["ColorSequence"] = {
		Sanitize = function(input: ColorSequence)
			local keypoints = input.Keypoints
			local sanitizedKeypoints = table.create(#keypoints)

			for i, k in ipairs(keypoints) do
				sanitizedKeypoints[i] = {
					Time = k.Time,
					Value = {
						math.round(k.Value.R * 255),
						math.round(k.Value.G * 255),
						math.round(k.Value.B * 255),
					},
				}
			end

			return {
				__sanitize = "ColorSequence",
				Keypoints = sanitizedKeypoints,
			}
		end,
		Desanitize = function(input)
			local keys = table.create(#input.Keypoints)
			for i, k in pairs(input.Keypoints) do
				keys[i] = ColorSequenceKeypoint.new(k.Time, Color3.fromRGB(k.Value.R, k.Value.G, k.Value.B))
			end

			return ColorSequence.new(keys)
		end,
	},
	["DateTime"] = {
		Sanitize = function(input: DateTime)
			return {
				__sanitize = "DateTime",
				Timestamp = input.UnixTimestampMillis,
			}
		end,
		Desanitize = function(input)
			return DateTime.fromUnixTimestampMillis(input.Timestamp)
		end,
	},
	["EnumItem"] = {
		Sanitize = function(input: EnumItem)
			return {
				__sanitize = "EnumItem",
				Name = input.Name,
				ParentName = tostring(input.EnumType),
			}
		end,
		Desanitize = function(input)
			return Enum[input.ParentName][input.Name]
		end,
	},
	["Faces"] = {
		Sanitize = function(input: Faces)
			return {
				__sanitize = "Faces",
				Top = input.Top,
				Bottom = input.Bottom,
				Left = input.Left,
				Right = input.Right,
				Back = input.Back,
				Front = input.Front,
			}
		end,
		Desanitize = function(input)
			return Faces.new(
				input.Top and Enum.NormalId.Top or nil,
				input.Bottom and Enum.NormalId.Bottom or nil,
				input.Left and Enum.NormalId.Left or nil,
				input.Right and Enum.NormalId.Right or nil,
				input.Back and Enum.NormalId.Back or nil,
				input.Front and Enum.NormalId.Front or nil
			)
		end,
	},
	["Instance"] = {
		Sanitize = function(input: Instance)
			return {
				__sanitize = "Instance",
				FullName = input:GetFullName(),
			}
		end,
		Desanitize = function(input)
			local path = string.split(input.FullName, ".")
			local obj = game
			for _, parent in ipairs(path) do
				if obj == nil then
					return nil
				end
				obj = obj:FindFirstChild(parent)
			end

			return obj
		end,
	},
	["NumberRange"] = {
		Sanitize = function(input: NumberRange)
			return {
				__sanitize = "NumberRange",
				Min = input.Min,
				Max = input.Max,
			}
		end,
		Desanitize = function(input)
			return NumberRange.new(input.Min, input.Max)
		end,
	},
	["NumberSequence"] = {
		Sanitize = function(input: NumberSequence)
			local keypoints = input.Keypoints
			local sanitizedKeypoints = table.create(#keypoints)

			for i, k in ipairs(keypoints) do
				sanitizedKeypoints[i] = {
					Time = k.Time,
					Value = k.Value,
					Env = k.Envelope,
				}
			end

			return {
				__sanitize = "NumberSequence",
				Keypoints = sanitizedKeypoints,
			}
		end,
		Desanitize = function(input)
			local keys = table.create(#input.Keypoints)
			for i, k in pairs(input.Keypoints) do
				keys[i] = NumberSequenceKeypoint.new(k.Time, k.Value, k.Env)
			end

			return NumberSequence.new(keys)
		end,
	},
	["PhysicalProperties"] = {
		Sanitize = function(input: PhysicalProperties)
			return {
				__sanitize = "PhysicalProperties",
				Density = input.Density,
				Friction = input.Friction,
				Elasticity = input.Elasticity,
				FrictionWeight = input.FrictionWeight,
				ElasticityWeight = input.ElasticityWeight,
			}
		end,
		Desanitize = function(input)
			return PhysicalProperties.new(
				input.Density,
				input.Friction,
				input.Elasticity,
				input.FrictionWeight,
				input.ElasticityWeight
			)
		end,
	},
	["Ray"] = {
		Sanitize = function(input: Ray)
			return {
				__sanitize = "Ray",
				Origin = { X = input.Origin.X, Y = input.Origin.Y, Z = input.Origin.Z },
				Direction = { X = input.Direction.X, Y = input.Direction.Y, Z = input.Direction.Z },
			}
		end,
		Desanitize = function(input)
			return Ray.new(
				Vector3.new(input.Origin.X, input.Origin.Y, input.Origin.Z),
				Vector3.new(input.Direction.X, input.Direction.Y, input.Direction.Z)
			)
		end,
	},
	["Rect"] = {
		Sanitize = function(input: Rect)
			return {
				__sanitize = "Rect",
				MinX = input.Min.X,
				MaxX = input.Max.X,
				MinY = input.Min.Y,
				MaxY = input.Max.Y,
			}
		end,
		Desanitize = function(input)
			return Rect.new(input.MinX, input.MinY, input.MaxX, input.MaxY)
		end,
	},
	["UDim"] = {
		Sanitize = function(input: UDim)
			return {
				__sanitize = "UDim",
				Scale = input.Scale,
				Offset = input.Offset,
			}
		end,
		Desanitize = function(input)
			return UDim.new(input.Scale, input.Offset)
		end,
	},
	["UDim2"] = {
		Sanitize = function(input: UDim2)
			return {
				__sanitize = "UDim2",
				xScale = input.X.Scale,
				xOffset = input.X.Offset,
				yScale = input.Y.Scale,
				yOffset = input.Y.Offset,
			}
		end,
		Desanitize = function(input)
			return UDim2.new(input.xScale, input.xOffset, input.yScale, input.yOffset)
		end,
	},
	["Vector2"] = {
		Sanitize = function(input: Vector2)
			return {
				__sanitize = "Vector2",
				X = input.X,
				Y = input.Y,
			}
		end,
		Desanitize = function(input)
			return Vector2.new(input.X, input.Y)
		end,
	},
	["Vector3"] = {
		Sanitize = function(input: Vector3)
			return {
				__sanitize = "Vector3",
				X = input.X,
				Y = input.Y,
				Z = input.Z,
			}
		end,
		Desanitize = function(input)
			return Vector3.new(input.X, input.Y, input.Z)
		end,
	},
}
module.SupportedTypes = {}
for key in pairs(TypeHandlers) do
	module.SupportedTypes[key] = true
end

function module:Sanitize(Object: any)
	local objType = typeof(Object)
	if TypeHandlers[objType] then
		return TypeHandlers[objType].Sanitize(Object)
	end

	if objType ~= "table" then
		return Object
	end

	local SanitizedTable = table.create(#Object)

	for Key, Value in pairs(Object) do
		local KeyType = typeof(Key)
		local ValueType = typeof(Value)

		local SanitizedKey, SanitizedValue = nil, nil

		if ValueType == "table" then
			SanitizedValue = self:Sanitize(Value)
		else
			local Handler = TypeHandlers[ValueType]
			if Handler then
				SanitizedValue = Handler.Sanitize(Value)
			else
				SanitizedValue = Value
			end
		end

		if KeyType == "table" then
			SanitizedKey = self:Sanitize(Key)
		else
			local Handler = TypeHandlers[KeyType]
			if Handler then
				SanitizedKey = Handler.Sanitize(Key)
			else
				SanitizedKey = Key
			end
		end

		SanitizedTable[SanitizedKey] = SanitizedValue
	end

	return SanitizedTable
end

function module:Desanitize(SanitizedObject: {__sanitize: string?})
	if SanitizedObject.__sanitize then
		local Handler = TypeHandlers[SanitizedObject.__sanitize]
		return Handler.Desanitize(SanitizedObject)
	end

	local RegularTable: {[any]: any} = table.create(#SanitizedObject)

	for Key, Value in pairs(SanitizedObject) do
		local KeyType = typeof(Key)
		local ValueType = typeof(Value)

		local RegularKey, RegularValue = nil, nil

		if ValueType == "table" then
			if Value.__sanitize then
				local Handler = TypeHandlers[Value.__sanitize]
				RegularValue = Handler.Desanitize(Value)
			else
				RegularValue = self:Desanitize(Value)
			end
		else
			RegularValue = Value
		end

		if KeyType == "table" then
			if Key.__sanitize then
				local Handler = TypeHandlers[Key.__sanitize]
				RegularKey = Handler.Desanitize(Key)
			else
				RegularKey = self:Desanitize(Key)
			end
		else
			RegularKey = Key
		end

		RegularTable[RegularKey] = RegularValue
	end

	return RegularTable
end

return module
