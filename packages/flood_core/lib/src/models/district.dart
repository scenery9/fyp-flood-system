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

/// Returns the official spelling, or null if [name] is not a Selangor district.
/// Accepts any letter case and extra spaces ("  kuala  selangor ").
String? normaliseDistrict(String? name) {
  if (name == null) return null;
  final n = name.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  return selangorDistricts.contains(n) ? n : null;
}
