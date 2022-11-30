module mir.toml.annotations;

import mir.serde;
import mir.ion.exception;
import mir.ion.value;

alias tomlInlineArray = serdeTransformOut!(v => TomlInlineArray!(typeof(v))(v));
alias tomlInlineTable = serdeTransformOut!(v => TomlInlineTable!(typeof(v))(v));
alias tomlLiteralString = serdeTransformOut!(v => TomlString!(false, true)(v));
alias tomlMultilineString = serdeTransformOut!(v => TomlString!(true, false)(v));
alias tomlMultilineLiteralString = serdeTransformOut!(v => TomlString!(true, true)(v));

struct TomlInlineTable(T)
{
	T value;

	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (value.descriptor.type == IonTypeCode.struct_)
			cast()this.value = deserializeIon!T(symbolTable, value);
		else
			return ionException(IonErrorCode.expectedStructValue);
		return null;
	}

	void serialize(S)(scope ref S serializer) const scope
	{
		import mir.ser : serializeValue;
		import mir.toml.serializer;

		static if (is(immutable S == immutable TOMLSerializer!U, U))
		{
			bool removeFlag = serializer.pushFlag(SerializationFlag.inlineTable);
			scope (exit)
				if (removeFlag)
					serializer.removeFlag(SerializationFlag.inlineTable);
		}
		serializeValue(serializer, value);
	}
}

struct TomlInlineArray(T)
{
	T value;

	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (value.descriptor.type == IonTypeCode.array)
			cast()this.value = deserializeIon!T(symbolTable, value);
		else
			return ionException(IonErrorCode.expectedStructValue);
		return null;
	}

	void serialize(S)(scope ref S serializer) const scope
	{
		import mir.ser : serializeValue;
		import mir.toml.serializer;

		static if (is(immutable S == immutable TOMLSerializer!U, U))
		{
			bool removeFlag = serializer.pushFlag(SerializationFlag.inlineArray);
			scope (exit)
				if (removeFlag)
					serializer.removeFlag(SerializationFlag.inlineArray);
		}
		serializeValue(serializer, value);
	}
}

struct TomlString(bool multiline, bool literal)
{
	string value;

	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (value.descriptor.type == IonTypeCode.string)
			this.value = deserializeIon!T(symbolTable, value);
		else
			return ionException(IonErrorCode.expectedStringValue);
		return null;
	}

	void serialize(S)(scope ref S serializer) const scope
	{
		import mir.ser : serializeValue;
		import mir.toml.serializer;

		static if (multiline && literal)
			enum flag = SerializationFlag.multilineLiteralString;
		else static if (multiline)
			enum flag = SerializationFlag.multilineString;
		else static if (literal)
			enum flag = SerializationFlag.literalString;
		else
			enum flag = SerializationFlag.none;

		static if (is(immutable S == immutable TOMLSerializer)
			&& flag != SerializationFlag.none)
		{
			bool removeFlag = serializer.pushFlag(flag);
			scope (exit)
				if (removeFlag)
					serializer.removeFlag(flag);
		}
		serializeValue(serializer, value);
	}
}
