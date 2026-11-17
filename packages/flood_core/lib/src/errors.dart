/// Thrown when a station id does not exist in the repository.
class UnknownStationException implements Exception {
  UnknownStationException(this.stationId);
  final String stationId;
  @override
  String toString() => 'UnknownStationException: no station "$stationId"';
}

/// Thrown when the user tries to follow more areas than allowed.
class FollowLimitReachedException implements Exception {
  FollowLimitReachedException(this.limit);
  final int limit;
  @override
  String toString() => 'FollowLimitReachedException: maximum $limit areas';
}

/// Thrown when input from a form is not acceptable. [message] can be shown to the user.
class ValidationException implements Exception {
  ValidationException(this.message);
  final String message;
  @override
  String toString() => 'ValidationException: $message';
}

/// Thrown when a staff-only function is called without a staff session.
class NotSignedInException implements Exception {
  @override
  String toString() => 'NotSignedInException: staff login required';
}

/// Thrown when the signed-in staff member's role does not allow the action.
class PermissionDeniedException implements Exception {
  PermissionDeniedException(this.permission);
  final String permission;
  @override
  String toString() => 'PermissionDeniedException: needs "$permission"';
}

/// Thrown when a record with the given id does not exist.
class NotFoundException implements Exception {
  NotFoundException(this.what, this.id);
  final String what;
  final String id;
  @override
  String toString() => 'NotFoundException: no $what "$id"';
}

/// Thrown when the action clashes with the current data (e.g. already reviewed).
class ConflictException implements Exception {
  ConflictException(this.message);
  final String message;
  @override
  String toString() => 'ConflictException: $message';
}

/// Thrown when a route could not be fetched or understood.
class RoutingException implements Exception {
  RoutingException(this.message);
  final String message;
  @override
  String toString() => 'RoutingException: $message';
}

/// Thrown when forecast.json is not in the expected format.
class ForecastFormatException implements Exception {
  ForecastFormatException(this.message);
  final String message;
  @override
  String toString() => 'ForecastFormatException: $message';
}
