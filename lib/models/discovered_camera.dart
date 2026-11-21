/// The discovery metadata advertised by an ONVIF device, before authentication.
class DiscoveredCamera {
  DiscoveredCamera({
    required this.address,
    required Iterable<String> types,
    required Iterable<String> scopes,
    required Iterable<String> xAddrs,
  }) : types = List.unmodifiable(types.toSet()),
       scopes = List.unmodifiable(scopes.toSet()),
       xAddrs = List.unmodifiable(xAddrs.toSet());

  final String address;
  final List<String> types, scopes, xAddrs;

  /// One device may advertise additional addresses on another interface.
  DiscoveredCamera merge(DiscoveredCamera other) {
    final merged = DiscoveredCamera(
      address: address,
      types: [...types, ...other.types],
      scopes: [...scopes, ...other.scopes],
      xAddrs: [...xAddrs, ...other.xAddrs],
    );
    return merged.types.length == types.length &&
            merged.scopes.length == scopes.length &&
            merged.xAddrs.length == xAddrs.length
        ? this
        : merged;
  }
}
