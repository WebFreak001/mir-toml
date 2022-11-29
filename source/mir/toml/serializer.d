module mir.toml.serializer;

debug = Pops;

import mir.bignum.decimal : Decimal;
import mir.bignum.integer : BigInt;
import mir.bignum.low_level_view : BigIntView;
import mir.format : printZeroPad;
import mir.ion.exception;
import mir.ion.type_code : IonTypeCode;
import mir.lob : Blob, Clob;
import mir.primitives : isOutputRange;
import mir.timestamp : Timestamp;

import std.algorithm : among, canFind;
import std.array : join, replace;
import std.ascii : hexDigits;
import std.bitmanip : bitfields;
import std.conv : text, to;
import std.math : isNaN;
import std.meta : AliasSeq;
import std.regex : Captures, ctRegex, matchFirst, replaceAll;
import std.typecons : isBitFlagEnum;

///
struct TOMLBeautyConfig
{
	/// Uses inline tables inside arrays, no nested struct indent, no spaces
	/// around equals signs, no number separators, arrays are single line
	static immutable TOMLBeautyConfig minify = {
		fullTablesInArrays: false,
		spaceAroundEquals: false,
		decimalThousandsSeparatorThreshold: 0,
		binaryOctetSeparator: false,
		arrayIndent: "",
	};
	/// Uses inline tables inside arrays, no nested struct indent, adds spaces
	/// around equals signs, no number separators, arrays are single line
	static immutable TOMLBeautyConfig none = {
		fullTablesInArrays: false,
		decimalThousandsSeparatorThreshold: 0,
		binaryOctetSeparator: false,
		arrayIndent: "",
	};
	/// Uses inline tables inside arrays, no nested struct indent, adds spaces
	/// around equals signs, enabled decimal thousands separator at 5 digits,
	/// enabled binary octet separators, arrays are single line
	static immutable TOMLBeautyConfig numbers = {
		fullTablesInArrays: false,
		arrayIndent: "",
	};
	/// Uses proper tables inside arrays, no nested struct indent, adds spaces
	/// around equals, no number separators, arrays are single line
	static immutable TOMLBeautyConfig nestedTables = {
		fullTablesInArrays: false,
		decimalThousandsSeparatorThreshold: 0,
		binaryOctetSeparator: false,
		arrayIndent: "",
	};
	/// Uses proper tables inside arrays, 2-space struct indent, adds spaces
	/// around equals, no number separators, arrays are single line
	static immutable TOMLBeautyConfig indentedTables = {
		structIndent: "  ",
		decimalThousandsSeparatorThreshold: 0,
		binaryOctetSeparator: false,
		arrayIndent: "",
	};
	/// Uses proper tables inside arrays, two space indent for nested structs,
	/// adds spaces around equals, enabled decimal thousands separator at 5
	/// digits, enabled binary octet separators, arrays are multi-line
	static immutable TOMLBeautyConfig full = {
		structIndent: "  "
	};

	string structIndent = "";
	string arrayIndent = "  ";
	bool fullTablesInArrays = true;
	bool arrayTrailingComma; // TODO
	string multilineStringIndent = ""; // TODO
	bool spaceAroundEquals = true;
	/// After how many decimal places to start putting thousands separators (_)
	/// or 0 to disable.
	int decimalThousandsSeparatorThreshold = 5; // TODO
	bool binaryOctetSeparator = true; // TODO
	bool hexWordSeparator = false; // TODO
	bool endOfFileNewline = true;
}

package enum SerializationFlag
{
	none = 0,
	inlineTable = 1 << 0,
	inlineArray = 1 << 1,
	literalString = 1 << 2, /// String with `'` as quotes
	multilineString = 1 << 3, /// String with `"""` as quotes
	multilineLiteralString = 1 << 4, /// String with `'''` as quotes
}

private enum CurrentType
{
	root, /// Before any `[sections]`
	table, /// `[fieldName]` table
	inlineTable, /// `fieldName = {}`
	array, /// `fieldName = [...]`
	tableArray /// `[[fieldName]]` table
}

private struct ParseInfo
{
	mixin(bitfields!(
		CurrentType, "type", 3,
		bool, "firstEntry", 1,
		bool, "closedScope", 1,
		uint, "", 3
	));

@safe pure scope:

	string toString() const
	{
		import std.conv : text;
	
		return text("ParseInfo(", type, ", firstEntry: ", firstEntry, ", closedScope: ", closedScope, ")");
	}

	static ParseInfo root()
	{
		ParseInfo ret;
		ret.type = CurrentType.root;
		ret.firstEntry = true;
		return ret;
	}

	static ParseInfo table()
	{
		ParseInfo ret;
		ret.type = CurrentType.table;
		ret.firstEntry = true;
		return ret;
	}

	static ParseInfo inlineTable()
	{
		ParseInfo ret;
		ret.type = CurrentType.inlineTable;
		ret.firstEntry = true;
		return ret;
	}

	static ParseInfo array()
	{
		ParseInfo ret;
		ret.type = CurrentType.array;
		ret.firstEntry = true;
		return ret;
	}

	static ParseInfo tableArray()
	{
		ParseInfo ret;
		ret.type = CurrentType.tableArray;
		ret.firstEntry = true;
		return ret;
	}
}

private struct ParseInfoStack
{
	ParseInfo[32] stack;
	ParseInfo[] buffer;
	size_t len;
	debug (Pops)
		string[] popHistory;

@safe pure scope:

	@disable this(this);

	alias list this;

	inout(ParseInfo[]) list() inout scope return
	{
		return buffer[0 .. len];
	}

	ref ParseInfo current() scope return
	{
		if (buffer is null)
			buffer = stack[1 .. $];

		if (len > 0 && len <= buffer.length)
			return buffer[len - 1];
		else
			return stack[0];
	}

	debug (Pops)
	{
		void push(ParseInfo i, string file = __FILE__, size_t line = __LINE__)
		{
			import std.range : repeat;

			popHistory ~= text("  ".repeat(len).join, "- push ", file, ":", line, " ", i);
			if (buffer is null)
				buffer = stack[1 .. $];

			if (len >= buffer.length)
				buffer.length *= 2;
			buffer[len++] = i;
		}

		void pop(string file = __FILE__, size_t line = __LINE__)
		{
			import std.range : repeat;

			assert(len > 0, "too many pops! stack history:\n" ~ popHistory.join("\n"));
			len--;
			popHistory ~= text("  ".repeat(len).join, "-  pop ", file, ":", line, " ", buffer[len]);
		}
	}
	else
	{
		void push(ParseInfo i)
		{
			if (buffer is null)
				buffer = stack[1 .. $];

			if (len >= buffer.length)
				buffer.length *= 2;
			buffer[len++] = i;
		}

		void pop()
		{
			assert(len > 0);
			len--;
		}
	}

	bool inInlineTable()
	{
		foreach (ParseInfo pi; list)
			if (pi.type == CurrentType.table)
				return true;
		return false;
	}

	bool inArray()
	{
		foreach (ParseInfo pi; list)
			if (pi.type == CurrentType.array)
				return true;
		return false;
	}
}

static assert(isBitFlagEnum!SerializationFlag);

struct TOMLSerializer(Appender)
{
	TOMLBeautyConfig beautyConfig;

	private SerializationFlag currentFlags;
	private bool expectComma, expectSection;
	private char[256] currentKeyBuffer;
	private const(char)[] currentFullKey;
	private size_t keyArrayEnd;
	private size_t currentTableArrayKeyEnd;
	private ParseInfoStack stack;
	private CurrentType lastClosedScope;

	/++
	TOML string buffer
	+/
	Appender* appender;

@safe scope:
	@disable this(this);

	private const(char)[] currentKey()
	{
		if (keyArrayEnd)
			return currentFullKey[keyArrayEnd + 1 .. $];
		else
			return currentFullKey;
	}

	package bool pushFlag(SerializationFlag f)
	{
		if (hasFlag(f))
			return false;
		currentFlags |= f;
		return true;
	}

	package void removeFlag(SerializationFlag f)
	{
		currentFlags &= ~f;
	}

	package bool hasFlag(SerializationFlag f)
	{
		return (currentFlags & f) == f;
	}

	private void putStartOfLine() scope
	{
		bool hasStruct = beautyConfig.structIndent.length > 0;
		bool hasArray = beautyConfig.arrayIndent.length > 0;
		if (hasStruct || hasArray)
			foreach (state; stack)
			{
				if (hasStruct && state.type == CurrentType.table)
				{
					if (beautyConfig.structIndent.length == 1)
						appender.put(beautyConfig.structIndent[0]);
					else
						appender.put(beautyConfig.structIndent);
				}
				if (hasArray && state.type == CurrentType.array)
				{
					if (beautyConfig.arrayIndent.length == 1)
						appender.put(beautyConfig.arrayIndent[0]);
					else
						appender.put(beautyConfig.arrayIndent);
				}
			}
	}

	///
	size_t stringBegin()
	{
		if (hasFlag(SerializationFlag.literalString))
			appender.put('\'');
		else if (hasFlag(SerializationFlag.multilineString))
			appender.put(`"""`);
		else if (hasFlag(SerializationFlag.multilineLiteralString))
			appender.put(`'''`);
		else
			appender.put('"');
		return 0;
	}

	/++
	Puts string part. The implementation allows to split string unicode points.
	+/
	void putStringPart(scope const(char)[] value)
	{
		static string replaceChar(dchar c)
		{
			switch (c)
			{
			case '\x08':
				return `\b`;
			case '\x09':
				return `\t`;
			case '\x0a':
				return `\n`;
			case '\x0c':
				return `\f`;
			case '\x0d':
				return `\r`;
			case '\x22':
				return `\"`;
			case '\x5c':
				return `\\`;
			default:
				char[6] hex = '0';
				hex[0] = '\\';
				hex[1] = 'u';
				int pos = hex.length - 1;
				uint i = cast(uint)c;
				assert(i <= ushort.max);
				while (i > 0)
				{
					hex[pos--] = hexDigits[i % 16];
					i /= 16;
				}
				return hex[].idup;
			}
		}

		static string replaceMatch(scope Captures!(const(char)[]) m)
		{
			assert(m.hit.length == 1);
			return replaceChar(m.hit[0]);
		}

		// need escape: backslash and the control characters other than tab, line feed, and carriage return
		// (U+0000 to U+0008, U+000B, U+000C, U+000E to U+001F, U+007F).
		static immutable needEscape = ctRegex!`[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]`;

		bool isLiteral;
		bool isMultiline;
		if (hasFlag(SerializationFlag.literalString) || hasFlag(SerializationFlag.multilineLiteralString))
			isLiteral = true;
		if (hasFlag(SerializationFlag.multilineString) || hasFlag(SerializationFlag.multilineLiteralString))
			isMultiline = true;

		if (isLiteral && value.matchFirst(needEscape))
			throw new IonException("Tried to serialize string as literal containg "
				~ "a control character, which is not supported by this string type.");
		else
			value = value.replaceAll!replaceMatch(needEscape);

		if (isLiteral && isMultiline)
		{
			if (value.canFind(`'''`))
				throw new IonException("Tried to serialize string as multiline literal containg "
					~ "`'''`, which is not supported by this string type.");
		}
		else if (isLiteral)
		{
			if (value.canFind(`'`))
				throw new IonException("Tried to serialize string as literal containg "
					~ "`'`, which is not supported by this string type.");
		}
		else if (isMultiline)
		{
			value = value.replace(`\`, `\\`).replace(`"""`, `""\"`);
		}
		else
		{
			value = value.replace(`\`, `\\`).replace(`"`, `\"`);
		}

		appender.put(value);
	}

	///
	void stringEnd(size_t state)
	{
		if (hasFlag(SerializationFlag.literalString))
			appender.put('\'');
		else if (hasFlag(SerializationFlag.multilineString))
			appender.put(`"""`);
		else if (hasFlag(SerializationFlag.multilineLiteralString))
			appender.put(`'''`);
		else
			appender.put('"');
	}

	// ///
	// void putAnnotation(scope const(char)[] annotation)
	// {
	// }

	// ///
	// size_t annotationsEnd(size_t state)
	// {
	// }

	// ///
	// size_t annotationWrapperBegin()
	// {
	// }

	// ///
	// void annotationWrapperEnd(size_t annotationsState, size_t state)
	// {
	// }

	///
	size_t structBegin(size_t length = size_t.max)
	{
		if (stack.current.type == CurrentType.tableArray)
		{
			auto previousKey = keyArrayEnd;
			keyArrayEnd = currentFullKey.length;
			if (stack.current.firstEntry)
				appender.put('\n');
			else
				appender.put("\n\n");
			putStartOfLine();
			appender.put("[[");
			appender.put(currentFullKey);
			appender.put("]]");
			stack.push(ParseInfo.inlineTable);
			stack.current.firstEntry = false;
			lastClosedScope = CurrentType.root;
			return previousKey;
		}
		else if (hasFlag(SerializationFlag.inlineTable) || stack.current.type.among!(CurrentType.inlineTable, CurrentType.array))
		{
			putKeyImpl();
			appender.put('{');
			stack.push(ParseInfo.inlineTable);
			lastClosedScope = CurrentType.root;
			return keyArrayEnd;
		}
		else if (currentKey.length)
		{
			auto previousKey = keyArrayEnd;
			keyArrayEnd = currentFullKey.length;
			if (stack.current.firstEntry)
				appender.put('\n');
			else
				appender.put("\n\n");
			putStartOfLine();
			appender.put('[');
			appender.put(currentFullKey);
			appender.put(']');
			stack.current.firstEntry = false;
			stack.push(ParseInfo.table);
			lastClosedScope = CurrentType.root;
			return previousKey;
		}
		else
		{
			stack.push(ParseInfo.root);
			return keyArrayEnd;
		}
	}

	///
	void structEnd(size_t state)
	{
		if (stack.current.type == CurrentType.inlineTable)
		{
			stack.pop();
			if (beautyConfig.spaceAroundEquals)
				appender.put(" }");
			else
				appender.put('}');
			lastClosedScope = CurrentType.inlineTable;
		}
		else
		{
			lastClosedScope = stack.current.type;
			if (stack.current.type == CurrentType.root && beautyConfig.endOfFileNewline)
				appender.put('\n'); // end of file
			stack.pop();
		}
		keyArrayEnd = state;
		dropKey();
	}

	///
	size_t listBegin(size_t length = size_t.max)
	{
		if (hasFlag(SerializationFlag.inlineArray)
			|| stack.current.type.among!(CurrentType.inlineTable, CurrentType.array, CurrentType.tableArray)
			|| !beautyConfig.fullTablesInArrays)
		{
			putKeyImpl();
			appender.put('[');
			stack.push(ParseInfo.array);
			lastClosedScope = CurrentType.root;
			return keyArrayEnd;
		}
		else
		{
			auto previousKey = keyArrayEnd;
			keyArrayEnd = currentFullKey.length;
			stack.push(ParseInfo.tableArray);
			currentTableArrayKeyEnd = previousKey;
			lastClosedScope = CurrentType.root;
			return previousKey;
		}
	}

	///
	void elemBegin()
	{
	}

	///
	alias sexpElemBegin = elemBegin;

	///
	void listEnd(size_t state)
	{
		if (stack.current.type == CurrentType.array)
		{
			stack.pop();
			if (beautyConfig.spaceAroundEquals)
				appender.put(" ]");
			else
				appender.put(']');
			lastClosedScope = CurrentType.root;
		}
		else if (stack.current.firstEntry)
		{
			lastClosedScope = CurrentType.root;
			keyArrayEnd = state;
			appender.put(currentKey);
			if (beautyConfig.spaceAroundEquals)
				appender.put(" = []");
			else
				appender.put("=[]");
		}
		else
		{
			lastClosedScope = stack.current.type;
			stack.pop();
			appender.put('\n');
		}
		keyArrayEnd = state;
		dropKey();
	}

	///
	alias sexpBegin = listBegin;

	///
	alias sexpEnd = listEnd;

	///
	void nextTopLevelValue()
	{
	}

	///
	void putKey(scope const char[] key) @trusted
	{
		if (currentFullKey.length)
		{
			if (currentFullKey.length + 1 + key.length < currentKeyBuffer.length
				&& currentFullKey.ptr is currentKeyBuffer.ptr)
			{
				currentKeyBuffer.ptr[currentFullKey.length] = '.';
				currentKeyBuffer.ptr[currentFullKey.length + 1 .. currentFullKey.length + 1 + key.length] = key;
				currentFullKey = currentKeyBuffer.ptr[0 .. currentFullKey.length + 1 + key.length];
			}
			else
			{
				currentFullKey = text(currentFullKey, ".", key);
			}
		}
		else
		{
			if (key.length < currentKeyBuffer.length)
			{
				currentKeyBuffer.ptr[0 .. key.length] = key;
				currentFullKey = currentKeyBuffer.ptr[0 .. key.length];
			}
			else
			{
				currentFullKey = key.idup;
			}
		}
	}

	private void dropKey()
	{
		currentFullKey = currentFullKey[0 .. keyArrayEnd];
	}

	private void putKeyImpl()
	{
		scope (exit)
			dropKey();

		if (lastClosedScope != CurrentType.root)
		{
			if (lastClosedScope == CurrentType.array)
				throw new IonException("Attempted to put TOML key after end of array [current key = " ~ currentFullKey.idup ~ "]");
			else if (lastClosedScope == CurrentType.inlineTable)
				throw new IonException("Attempted to put TOML key after end of inline table [current key = " ~ currentFullKey.idup ~ "]");
			else if (lastClosedScope == CurrentType.table || lastClosedScope == CurrentType.tableArray)
				throw new IonException("Can't put any more TOML keys after a table or array of tables has ended! "
					~ "Move value fields inside serialized struct before structs and struct arrays! [current key = " ~ currentFullKey.idup ~ "]");
			else
				assert(false, "unexpected lastClosedScope state in TOMLSerializer [current key = " ~ currentFullKey.idup ~ "]");
		}

		final switch (stack.current.type)
		{
			case CurrentType.tableArray:
				if (stack.current.firstEntry)
				{
					appender.put('\n');
					putStartOfLine();
					appender.put(currentFullKey[currentTableArrayKeyEnd + 1 .. keyArrayEnd]);
					keyArrayEnd = currentTableArrayKeyEnd;
					if (beautyConfig.spaceAroundEquals)
						appender.put(" = [");
					else
						appender.put("=[");
					stack.current.type = CurrentType.array;
					lastClosedScope = CurrentType.root;
					goto case CurrentType.array;
				}
				else
				{
					assert(false, "unexpected stack state in TOMLSerializer: currently in an array of tables, "
						~ "but trying to put a key instead of a table. Perhaps you tried to mix tables and values? "
						~ "[current key = " ~ currentFullKey.idup ~ "]");
				}
			case CurrentType.root:
			case CurrentType.table:
				if (stack.current.type == CurrentType.table || !stack.current.firstEntry)
					appender.put('\n');
				stack.current.firstEntry = false;
				putStartOfLine();
				appender.put(currentKey);
				if (beautyConfig.spaceAroundEquals)
					appender.put(" = ");
				else
					appender.put('=');
				break;
			case CurrentType.array:
				if (!stack.current.firstEntry)
					appender.put(',');
				stack.current.firstEntry = false;
				if (stack.inInlineTable || !beautyConfig.arrayIndent.length)
				{
					if (beautyConfig.spaceAroundEquals)
						appender.put(' ');
				}
				else
				{
					appender.put('\n');
					putStartOfLine();
				}
				break;
			case CurrentType.inlineTable:
				if (!stack.current.firstEntry)
					appender.put(',');
				stack.current.firstEntry = false;
				if (beautyConfig.spaceAroundEquals)
					appender.put(' ');
				appender.put(currentKey);
				if (beautyConfig.spaceAroundEquals)
					appender.put(" = ");
				else
					appender.put('=');
				break;
		}
	}

	///
	static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
		void putValue(T value)
		{
			putKeyImpl();
			appender.put(value.to!string);
		}

	///
	void putValue(scope ref const BigInt!128 value)
	{
		putKeyImpl();
		appender.put(value.toString);
	}

	///
	static foreach (T; AliasSeq!(float, double, real))
		void putValue(T value)
		{
			putKeyImpl();
			if (isNaN(value))
				appender.put("nan");
			else if (value == T.infinity)
				appender.put("inf");
			else if (value == -T.infinity)
				appender.put("-inf");
			else
				appender.put(value.to!string);
		}

	///
	void putValue(scope ref const Decimal!128 value)
	{
		putKeyImpl();
		value.toString(*appender);
	}

	///
	void putValue(typeof(null))
	{
		if (stack.current.type.among!(CurrentType.array, CurrentType.inlineTable))
		{
			throw new IonException("Tried to serialize null value inside array or inlineTable, which is forbidden.");
		}
		else
		{
			// ignore null values, no representation in TOML
			dropKey();
		}
	}

	/// ditto 
	void putNull(IonTypeCode code)
	{
		switch (code)
		{
		case IonTypeCode.list:
			putKeyImpl();
			appender.put("[]");
			break;
		default:
			putValue(null);
			break;
		}
	}

	///
	void putValue(bool b)
	{
		putKeyImpl();
		appender.put(b ? "true" : "false");
	}

	///
	void putValue(scope const char[] value)
	{
		putKeyImpl();
		auto s = stringBegin();
		putStringPart(value);
		stringEnd(s);
	}

	///
	void putValue(Timestamp t)
	{
		/*
		# offset datetime
		odt1 = 1979-05-27T07:32:00Z
		odt2 = 1979-05-27T00:32:00-07:00
		odt3 = 1979-05-27T00:32:00.999999-07:00

		# local datetime
		ldt1 = 1979-05-27T07:32:00
		ldt2 = 1979-05-27T00:32:00.999999

		# local date
		ld1 = 1979-05-27

		# local time
		lt1 = 07:32:00
		lt2 = 00:32:00.999999
		*/

		putKeyImpl();
		putTimestamp(*appender, t);
	}

	///
	int serdeTarget() nothrow const @property
	{
		return -1;
	}
}

///
void serializeToml(Appender, V)(scope ref Appender appender, scope auto ref V value, TOMLBeautyConfig config = TOMLBeautyConfig.none)
	if (isOutputRange!(Appender, const(char)[]) && isOutputRange!(Appender, char))
{
	static assert(is(V == struct), "serializeToml only works on structs!");

	import mir.ser : serializeValue;
	scope TOMLSerializer!Appender serializer;
	serializer.beautyConfig = config;
	serializer.appender = (() @trusted => &appender)();
	serializeValue(serializer, value);
}

/++
JSON serialization function with pretty formatting.
+/
string serializeToml(V)(scope auto ref const V value, TOMLBeautyConfig config = TOMLBeautyConfig.none)
{
	import std.array: appender;
	import mir.functional: forward;

	auto app = appender!(char[]);
	serializeToml(app, value, config);
	return (()@trusted => cast(string) app.data)();
}

private static void putTimestamp(Appender)(ref Appender w, Timestamp t)
{
	if (t.precision < Timestamp.Precision.day)
		throw new IonException("Timestamps with only year or month precision are not supported in TOML serialization");

	if (t.precision == Timestamp.Precision.minute)
	{
		t.second = 0;
		t.precision = Timestamp.Precision.second;
	}

	if (!t.isOnlyTime)
	{
		printZeroPad(w, t.year, 4);
		w.put('-');
		printZeroPad(w, cast(uint)t.month, 2);
		w.put('-');
		printZeroPad(w, cast(uint)t.day, 2);

		if (t.precision == Timestamp.Precision.day)
			return;
		w.put('T');
	}

	printZeroPad(w, t.hour, 2);
	w.put(':');
	printZeroPad(w, t.minute, 2);
	w.put(':');
	printZeroPad(w, t.second, 2);

	if (t.precision > Timestamp.Precision.second
		&& (t.fractionExponent < 0 && t.fractionCoefficient))
	{
		w.put('.');
		printZeroPad(w, t.fractionCoefficient, -int(t.fractionExponent));
	}

	if (t.isLocalTime)
		return;

	if (t.offset == 0)
	{
		w.put('Z');
		return;
	}

	bool sign = t.offset < 0;
	uint absoluteOffset = !sign ? t.offset : -int(t.offset);
	uint offsetHour = absoluteOffset / 60u;
	uint offsetMinute = absoluteOffset % 60u;

	w.put(sign ? '-' : '+');
	printZeroPad(w, offsetHour, 2);
	w.put(':');
	printZeroPad(w, offsetMinute, 2);
}
