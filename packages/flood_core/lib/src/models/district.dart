/// Selangor's nine districts, spelt exactly as the JPS Selangor feed spells
/// them (station `districtName`). Staff areas, resource points, relief centres
/// and damage reports all use these names, so the database and the app agree.
const List<String> selangorDistricts = [
  'GOMBAK',
  'HULU LANGAT',
  'HULU SELANGOR',
  'KLANG',
  'KUALA LANGAT',
  'KUALA SELANGOR',
  'PETALING',
  'SABAK BERNAM',
  'SEPANG',
];

/// Melaka's three districts, as the JPS Melaka pages spell them, in capitals
/// like Selangor's (supabase/places.sql adds the same names).
const List<String> melakaDistricts = [
  'ALOR GAJAH',
  'JASIN',
  'MELAKA TENGAH',
];

/// Every district the system knows (Selangor first, then Melaka).
const List<String> allDistricts = [...selangorDistricts, ...melakaDistricts];

/// The state a district belongs to, or null if it is not known.
String? stateOfDistrict(String? district) {
  final d = normaliseDistrict(district);
  if (d == null) return null;
  return selangorDistricts.contains(d) ? 'Selangor' : 'Melaka';
}

/// Returns the official spelling, or null if [name] is not a known district.
/// Accepts any letter case and extra spaces ("  kuala  selangor ").
String? normaliseDistrict(String? name) {
  if (name == null) return null;
  final n = name.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  return allDistricts.contains(n) ? n : null;
}
