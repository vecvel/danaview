import 'package:meta/meta.dart';

/// The optional personal details shown in Settings. Kept on the device only; every field may be
/// empty. [dateOfBirth] is a calendar date (no time of day).
@immutable
class UserProfile {
  final String name;
  final String email;
  final String phone;
  final DateTime? dateOfBirth;

  const UserProfile({
    this.name = '',
    this.email = '',
    this.phone = '',
    this.dateOfBirth,
  });

  static const UserProfile empty = UserProfile();

  bool get isEmpty =>
      name.trim().isEmpty && email.trim().isEmpty && phone.trim().isEmpty && dateOfBirth == null;

  bool get isNotEmpty => !isEmpty;

  /// Up to two letters for an avatar: first and last word of [name], else the first letter of
  /// [email]; empty when neither is set.
  String get initials {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isNotEmpty) {
      final first = _firstLetter(words.first);
      final last = words.length > 1 ? _firstLetter(words.last) : '';
      return (first + last).toUpperCase();
    }
    return _firstLetter(email.trim()).toUpperCase();
  }

  static String _firstLetter(String word) => word.isEmpty ? '' : String.fromCharCode(word.runes.first);

  /// Pass [clearDateOfBirth] to remove the date, since a null [dateOfBirth] keeps the current one.
  UserProfile copyWith({
    String? name,
    String? email,
    String? phone,
    DateTime? dateOfBirth,
    bool clearDateOfBirth = false,
  }) {
    return UserProfile(
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      dateOfBirth: clearDateOfBirth ? null : dateOfBirth ?? this.dateOfBirth,
    );
  }

  /// Text fields trimmed and the date reduced to a calendar day, as it is stored.
  UserProfile normalized() {
    final dob = dateOfBirth;
    return UserProfile(
      name: name.trim(),
      email: email.trim(),
      phone: phone.trim(),
      dateOfBirth: dob == null ? null : DateTime(dob.year, dob.month, dob.day),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'email': email,
        'phone': phone,
        if (dateOfBirth != null) 'dateOfBirth': _formatDate(dateOfBirth!),
      };

  /// Unknown or malformed values fall back to empty rather than throwing.
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    String text(String key) => json[key] is String ? json[key] as String : '';
    return UserProfile(
      name: text('name'),
      email: text('email'),
      phone: text('phone'),
      dateOfBirth: _parseDate(json['dateOfBirth']),
    );
  }

  static String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime(year, month, day);
    // DateTime rolls over out-of-range parts (e.g. 2023-02-30); reject those.
    if (date.year != year || date.month != month || date.day != day) return null;
    return date;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          name == other.name &&
          email == other.email &&
          phone == other.phone &&
          dateOfBirth == other.dateOfBirth;

  @override
  int get hashCode => Object.hash(name, email, phone, dateOfBirth);

  @override
  String toString() => 'UserProfile(name: $name, email: $email, phone: $phone, dateOfBirth: $dateOfBirth)';
}

/// Field checks for [UserProfile]. Every field is optional: an empty value is valid, and each
/// check returns a user-facing message, or null when the value is fine.
abstract final class ProfileValidation {
  static const int maxNameLength = 60;
  static const int maxEmailLength = 254;
  static const int minPhoneDigits = 7;
  static const int maxPhoneDigits = 15;
  static const int maxAgeYears = 120;

  // Lenient RFC 5322 subset: dot-atom local part, dotted host labels and a letter TLD.
  static final RegExp _emailPattern = RegExp(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*"
    r'@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$',
  );

  /// Digits with an optional leading +, and spaces, dashes, dots or parentheses as separators.
  static final RegExp _phonePattern = RegExp(r'^\+?[0-9 ().-]+$');

  static String? name(String value) {
    final length = value.trim().runes.length;
    if (length > maxNameLength) return 'Use $maxNameLength characters or fewer ($length now)';
    return null;
  }

  static String? email(String value) {
    final email = value.trim();
    if (email.isEmpty) return null;
    final at = email.lastIndexOf('@');
    if (email.length > maxEmailLength || at > 64 || !_emailPattern.hasMatch(email)) {
      return 'Enter an email like name@example.com';
    }
    return null;
  }

  static String? phone(String value) {
    final phone = value.trim();
    if (phone.isEmpty) return null;
    if (!_phonePattern.hasMatch(phone)) {
      return 'Use digits, an optional leading +, and spaces or dashes';
    }
    final digits = phone.runes.where((r) => r >= 0x30 && r <= 0x39).length;
    if (digits < minPhoneDigits || digits > maxPhoneDigits) {
      return 'Phone numbers have $minPhoneDigits to $maxPhoneDigits digits';
    }
    return null;
  }

  /// [now] defaults to the current time; the check compares calendar days.
  static String? dateOfBirth(DateTime? value, {DateTime? now}) {
    if (value == null) return null;
    final today = _day(now ?? DateTime.now());
    final date = _day(value);
    if (date.isAfter(today)) return "Date of birth can't be in the future";
    if (ageOn(date, today) > maxAgeYears) return 'Enter an age of $maxAgeYears or under';
    return null;
  }

  /// Completed years between [birth] and [on].
  static int ageOn(DateTime birth, DateTime on) {
    var age = on.year - birth.year;
    if (on.month < birth.month || (on.month == birth.month && on.day < birth.day)) age--;
    return age;
  }

  /// Earliest date of birth [dateOfBirth] accepts on [now].
  static DateTime earliestDateOfBirth({DateTime? now}) {
    final today = _day(now ?? DateTime.now());
    // The latest birth date already maxAge + 1 years old, then the day after it. A Feb 29 that
    // doesn't exist in that year falls back to Feb 28, matching [ageOn].
    var oldest = DateTime(today.year - maxAgeYears - 1, today.month, today.day);
    if (oldest.month != today.month) oldest = DateTime(oldest.year, today.month + 1, 0);
    return DateTime(oldest.year, oldest.month, oldest.day + 1);
  }

  static bool isValid(UserProfile profile, {DateTime? now}) =>
      name(profile.name) == null &&
      email(profile.email) == null &&
      phone(profile.phone) == null &&
      dateOfBirth(profile.dateOfBirth, now: now) == null;

  static DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);
}
