/// Deterministic XML serialisation matching lxml's C14N 2.0 output.
///
/// The invoice hash is SHA-256 over canonical XML bytes, so the Dart side
/// must produce **byte-identical** output to the Python reference
/// (`etree.tostring(root, method="c14n2")`). Rather than porting a general
/// canonicaliser, this writer serialises our own element tree directly in
/// canonical form — possible because we control every document we sign: no
/// comments, no CDATA, no attribute namespaces, fixed prefixes.
///
/// The rules, observed from the golden vectors and pinned by them in
/// `test/zatca/`:
///
/// * no XML declaration (canonical form), empty elements as `<a></a>`;
/// * a namespace declaration is emitted on the element where its prefix is
///   first used and not already declared by an emitted *ancestor* — root
///   carries only the default namespace, each `cbc:`/`cac:` element declares
///   its own prefix unless an ancestor already did;
/// * namespace declarations precede regular attributes;
/// * text escapes `& < >` and CR, attributes escape `& < "` and TAB/LF/CR.
library;

/// One element. [prefix] is null for the default namespace. [children] holds
/// [XmlEl] and [String] (text) nodes in document order.
class XmlEl {
  XmlEl(this.prefix, this.local,
      {List<(String, String)>? attrs, List<Object>? children})
      : attrs = attrs ?? const [],
        children = children ?? [];

  final String? prefix;
  final String local;

  /// Ordered (name, value) pairs. Never namespace declarations — the writer
  /// derives those from use.
  final List<(String, String)> attrs;

  final List<Object> children;

  void add(Object child) => children.add(child);
}

String _escText(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('\r', '&#xD;');

String _escAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('"', '&quot;')
    .replaceAll('\t', '&#x9;')
    .replaceAll('\n', '&#xA;')
    .replaceAll('\r', '&#xD;');

/// Serialise [root]. [namespaces] maps prefix (null = default) to URI and
/// must cover every prefix the tree uses. Elements matching [exclude] are
/// dropped with their subtrees — how the canonical form removes
/// `ext:UBLExtensions` before hashing. [xmlDeclaration] prepends the
/// declaration for the stored document form (never for hashing).
/// [declareAllAtRoot] hoists every namespace onto the root element, which is
/// the document form (what gets stored and reported). Canonical form — what
/// gets hashed — leaves it false so declarations land where first used.
String serializeXml(
  XmlEl root, {
  required Map<String?, String> namespaces,
  bool Function(XmlEl element)? exclude,
  bool xmlDeclaration = false,
  bool declareAllAtRoot = false,
}) {
  final out = StringBuffer();
  if (xmlDeclaration) {
    // Single quotes, like lxml writes it.
    out.write("<?xml version='1.0' encoding='UTF-8'?>\n");
  }
  _write(out, root, const {}, namespaces, exclude,
      rootDeclarations: declareAllAtRoot ? namespaces : null);
  return out.toString();
}

void _write(
  StringBuffer out,
  XmlEl el,
  Map<String?, String> inScope,
  Map<String?, String> namespaces,
  bool Function(XmlEl element)? exclude, {
  Map<String?, String>? rootDeclarations,
}) {
  if (exclude != null && exclude(el)) return;

  final uri = namespaces[el.prefix];
  if (uri == null) {
    throw ArgumentError('no namespace URI for prefix ${el.prefix}');
  }
  final name = el.prefix == null ? el.local : '${el.prefix}:${el.local}';

  var scope = inScope;
  out.write('<$name');
  if (rootDeclarations != null) {
    // Default namespace first, then prefixes alphabetically — the order
    // lxml writes an nsmap in.
    final prefixes = rootDeclarations.keys.toList()
      ..sort((a, b) => a == null ? -1 : (b == null ? 1 : a.compareTo(b)));
    for (final prefix in prefixes) {
      final decl = prefix == null ? 'xmlns' : 'xmlns:$prefix';
      out.write(' $decl="${_escAttr(rootDeclarations[prefix]!)}"');
    }
    scope = {...scope, ...rootDeclarations};
  } else if (scope[el.prefix] != uri) {
    final decl = el.prefix == null ? 'xmlns' : 'xmlns:${el.prefix}';
    out.write(' $decl="${_escAttr(uri)}"');
    scope = {...scope, el.prefix: uri};
  }
  for (final (attrName, attrValue) in el.attrs) {
    out.write(' $attrName="${_escAttr(attrValue)}"');
  }
  out.write('>');

  for (final child in el.children) {
    if (child is String) {
      out.write(_escText(child));
    } else {
      _write(out, child as XmlEl, scope, namespaces, exclude);
    }
  }
  out.write('</$name>');
}
