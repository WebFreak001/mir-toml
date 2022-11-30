module mir.toml.deserializer;

// debug = Deserializer;

static import toml;

import std.datetime.date;
import std.datetime.systime;
import std.meta;

import mir.timestamp : Timestamp;

template parseToml(T)
{
	void parseToml(scope const(char)[] inputData, ref T serializer) @safe
	{
		auto document = toml.parseTOML(inputData);
		serializeValue(document.table, serializer);
	}

@safe pure:

	private void serializeValue(scope toml.TOMLValue value, ref T serializer)
	{
		final switch (value.type)
		{
		case toml.TOML_TYPE.STRING:
			serializeValue(value.str, serializer);
			break;
		case toml.TOML_TYPE.INTEGER:
			serializeValue(value.integer, serializer);
			break;
		case toml.TOML_TYPE.FLOAT:
			serializeValue(value.floating, serializer);
			break;
		case toml.TOML_TYPE.TRUE:
			serializeValue(true, serializer);
			break;
		case toml.TOML_TYPE.FALSE:
			serializeValue(false, serializer);
			break;
		case toml.TOML_TYPE.OFFSET_DATETIME:
			serializeValue(value.offsetDatetime, serializer);
			break;
		case toml.TOML_TYPE.LOCAL_DATETIME:
			serializeValue(value.localDatetime, serializer);
			break;
		case toml.TOML_TYPE.LOCAL_DATE:
			serializeValue(value.localDate, serializer);
			break;
		case toml.TOML_TYPE.LOCAL_TIME:
			serializeValue(value.localTime, serializer);
			break;
		case toml.TOML_TYPE.ARRAY:
			serializeValue(value.array, serializer);
			break;
		case toml.TOML_TYPE.TABLE:
			serializeValue(value.table, serializer);
			break;
		}
	}

	static foreach (SimpleType; AliasSeq!(bool, const(char)[], long, double))
		private void serializeValue(scope SimpleType value, ref T serializer)
		{
			serializer.putValue(value);
		}

	static foreach (TimeType; AliasSeq!(SysTime, DateTime, Date, TimeOfDay))
		private void serializeValue(scope TimeType value, ref T serializer)
		{
			serializer.putValue(Timestamp(value));
		}

	private void serializeValue(scope toml.TOMLValue[] array, ref T serializer)
	{
		auto state = serializer.listBegin(array.length);
		foreach (value; array)
		{
			serializer.elemBegin();
			serializeValue(value, serializer);
		}
		serializer.listEnd(state);
	}

	private void serializeValue(scope toml.TOMLValue[string] table, ref T serializer)
	{
		auto state = serializer.structBegin(table.length);
		foreach (key, value; table)
		{
			serializer.putKey(key);
			serializeValue(value, serializer);
		}
		serializer.structEnd(state);
	}
}

debug (Deserializer)
{
	import mir.ser;
	import mir.bignum.decimal: Decimal;
	import mir.bignum.integer: BigInt;
	import mir.lob: Blob, Clob;
	import mir.timestamp: Timestamp;
	import mir.ion.type_code : IonTypeCode;

	struct DebugSerializer(T)
	{
		import std.algorithm;
		import std.range;
		import std.stdio;
		import std.string;

		T forwarder;
		private enum definedMethods = [
			"void putStringPart(scope const(char)[] value)",
			"void stringEnd(size_t state)",
			"size_t structBegin(size_t length = size_t.max)",
			"void structEnd(size_t state)",
			"size_t listBegin(size_t length = size_t.max)",
			"void listEnd(size_t state)",
			"size_t sexpBegin(size_t length = size_t.max)",
			"void sexpEnd(size_t state)",
			"void putSymbol(scope const char[] symbol)",
			"void putAnnotation(scope const(char)[] annotation)",
			"size_t annotationsEnd(size_t state)",
			"size_t annotationWrapperBegin()",
			"void annotationWrapperEnd(size_t annotationsState, size_t state)",
			"void nextTopLevelValue()",
			"void putKey(scope const char[] key)",
			"void putValue(long value)",
			"void putValue(ulong value)",
			"void putValue(float value)",
			"void putValue(double value)",
			"void putValue(real value)",
			"void putValue(scope ref const BigInt!128 value)",
			"void putValue(scope ref const Decimal!128 value)",
			"void putValue(typeof(null))",
			"void putNull(IonTypeCode code)",
			"void putValue(bool b)",
			"void putValue(scope const char[] value)",
			"void putValue(scope Clob value)",
			"void putValue(scope Blob value)",
			"void putValue(Timestamp value)",
			"void elemBegin()",
			"void sexpElemBegin()",
		];

		private static int prefixLength()
		{
			return __FUNCTION__.length - "prefixLength".length;
		}

		int fndepth;

	@safe:
		static foreach (method; definedMethods)
			mixin(method ~ " pure {
				enum fnname = __FUNCTION__[prefixLength..$];
				static if (fnname.length > 3 && fnname[$ - 3 .. $] == `End`)
					fndepth--;
				scope (exit)
				{
					static if (fnname.length > 5 && fnname[$ - 5 .. $] == `Begin`
						&& fnname != `elemBegin`)
						fndepth++;
				}
				static if (is(typeof(return) == void))
				{
					debug writeln(`  `.repeat(fndepth).join, '\\x1B', `[1m`, fnname, '\\x1B', `[0m`, `(`, __traits(parameters), `)`);
					__traits(getMember, forwarder, fnname)(__traits(parameters));
				}
				else
				{
					debug write(`  `.repeat(fndepth).join, '\\x1B', `[1m`, fnname, '\\x1B', `[0m`, `(`, __traits(parameters), `)`);
					auto ret = __traits(getMember, forwarder, fnname)(__traits(parameters));
					debug writeln(` -> `, ret);
					return ret;
				}
			}");
	}

	private auto makeDebugSerializer(T)(lazy T forwarder)
	{
		return DebugSerializer!T(forwarder);
	}
}

@trusted
immutable(ubyte)[] tomlToIon(scope const(char)[] inputData)
{
	import std.algorithm : move;
	import mir.appender : scopedBuffer;
	import mir.ion.symbol_table: IonSymbolTable;
    import mir.ion.internal.data_holder: ionPrefix;
	import mir.ser.ion : ionSerializer;
	import mir.serde : SerdeTarget;
	enum nMax = 4096;

	auto buf = scopedBuffer!ubyte;
	
	IonSymbolTable!false table = void;
	table.initialize;

	debug (Deserializer)
	{
		auto debugSerializer = makeDebugSerializer(ionSerializer!(nMax * 8, null, false));
		debugSerializer.forwarder.initialize(table);
		parseToml!(typeof(debugSerializer))(inputData, debugSerializer);
		ref auto serializer() { return debugSerializer.forwarder; }
	}
	else
	{
		auto serializer = ionSerializer!(nMax * 8, null, false);
		serializer.initialize(table);
		parseToml!(typeof(serializer))(inputData, serializer);
	}

	serializer.finalize;

	buf.put(ionPrefix);
	if (table.initialized)
	{
		table.finalize;
		buf.put(table.data);
	}
	buf.put(serializer.data);

	return buf.data.idup;
}

template deserializeToml(T)
{
	void deserializeToml(scope ref T value, scope const(char)[] data)
	{
		import mir.deser.ion : deserializeIon;

		return deserializeIon!T(value, tomlToIon(data));
	}

	T deserializeToml(scope const(char)[] data)
	{
		T value;
		deserializeToml(value, data);
		return value;
	}
}
