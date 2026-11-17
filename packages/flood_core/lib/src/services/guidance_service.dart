import '../models/app_settings.dart';
import '../models/risk_level.dart';
import '../models/station_status.dart';

/// "What To Do": short steps for each risk level.
/// DRAFT wording: review against official NADMA / JPS advice before release.
/// Chinese text is not written yet; it falls back to English.
class GuidanceService {
  const GuidanceService();

  static const Map<RiskLevel, List<String>> _en = {
    RiskLevel.normal: [
      'Keep following your area in the app.',
      'Know where your nearest relief centre is.',
      'Keep important documents in a waterproof bag.',
    ],
    RiskLevel.alert: [
      'Check the app often for updates.',
      'Charge your phone and power bank.',
      'Prepare an emergency bag: documents, medicine, water, torch.',
      'Move your vehicle and valuables to higher ground.',
    ],
    RiskLevel.warning: [
      'Be ready to leave at short notice.',
      'Switch off electricity and gas if water starts to enter.',
      'Help elderly people, children and neighbours get ready.',
      'Do not walk or drive through flood water.',
    ],
    RiskLevel.danger: [
      'Move to the nearest relief centre or higher ground now.',
      'Follow instructions from the authorities.',
      'Do not walk or drive through flood water.',
      'Call 999 if you are trapped or in danger.',
    ],
  };

  static const Map<RiskLevel, List<String>> _ms = {
    RiskLevel.normal: [
      'Terus ikuti kawasan anda dalam aplikasi.',
      'Ketahui lokasi pusat pemindahan terdekat.',
      'Simpan dokumen penting dalam beg kalis air.',
    ],
    RiskLevel.alert: [
      'Semak aplikasi dengan kerap untuk maklumat terkini.',
      'Cas telefon dan power bank anda.',
      'Sediakan beg kecemasan: dokumen, ubat, air, lampu suluh.',
      'Alihkan kenderaan dan barang berharga ke tempat tinggi.',
    ],
    RiskLevel.warning: [
      'Bersedia untuk berpindah pada bila-bila masa.',
      'Tutup bekalan elektrik dan gas jika air mula masuk.',
      'Bantu warga emas, kanak-kanak dan jiran bersiap sedia.',
      'Jangan meredah air banjir dengan berjalan kaki atau kenderaan.',
    ],
    RiskLevel.danger: [
      'Berpindah ke pusat pemindahan terdekat atau tempat tinggi sekarang.',
      'Ikut arahan pihak berkuasa.',
      'Jangan meredah air banjir dengan berjalan kaki atau kenderaan.',
      'Hubungi 999 jika anda terperangkap atau dalam bahaya.',
    ],
  };

  List<String> steps(RiskLevel level, {AppLanguage language = AppLanguage.en}) =>
      List.unmodifiable((language == AppLanguage.ms ? _ms : _en)[level]!);

  /// Steps for a station's current state. When the level is unknown or the
  /// data is old, the Alert steps are used so the advice stays on the safe side.
  List<String> forStatus(StationStatus status, {AppLanguage language = AppLanguage.en}) =>
      steps(status.isActionable ? status.level! : RiskLevel.alert, language: language);
}
