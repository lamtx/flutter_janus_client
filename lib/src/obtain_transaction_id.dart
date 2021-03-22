class ObtainTransactionId {
  var _id = 0;

  String next() {
    _id += 1;
    return _id.toString();
  }
}
