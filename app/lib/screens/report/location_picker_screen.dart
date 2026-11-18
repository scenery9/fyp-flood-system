import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_map.dart';
import '../../widgets/common.dart';

/// Pick the place of a report: tap the map to drop a pin, or use your own
/// location. Returns the point, or nothing when the user goes back.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, required this.start});
  final GeoPoint start;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  GeoPoint? _pin;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final near = _pin == null ? null : app.placeNear(_pin!);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Where was it?', 'Di mana?', '在哪里？'))),
      body: SafeArea(
        top: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: AppMap(
              you: app.userLocation,
              youLabel: context.tr('You are here', 'Anda di sini'),
              height: double.infinity,
              pins: [
                if (_pin != null)
                  MapPin(
                    id: 'report-pin',
                    at: _pin!,
                    color: const Color(0xFFB3261E),
                    icon: Icons.place,
                    selected: true,
                    semantics: context.tr('Chosen place', 'Tempat dipilih', '已选地点'),
                  ),
              ],
              onMapTap: (p) => setState(() => _pin = p),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kMargin, kGap, kMargin, kGap),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                  _pin == null
                      ? context.tr('Tap the map where the flooding is.', 'Tekan pada peta di tempat banjir.', '在地图上点选淹水的地点。')
                      : near == null
                          ? context.tr('Place chosen.', 'Tempat dipilih.', '已选择地点。')
                          : context.tr('Near $near', 'Berhampiran $near', '靠近$near'),
                  key: const ValueKey('picker-place'),
                  style: context.text.bodyLarge),
              const SizedBox(height: kGap),
              if (app.locationIssue == null) ...[
                OutlinedButton.icon(
                  key: const ValueKey('picker-mine'),
                  onPressed: () => setState(() => _pin = app.userLocation),
                  icon: const Icon(Icons.my_location),
                  label: Text(context.tr('Use my location', 'Guna lokasi saya', '使用我的位置')),
                ),
                const SizedBox(height: kGap),
              ],
              FilledButton(
                key: const ValueKey('picker-use'),
                onPressed: _pin == null ? null : () => Navigator.of(context).pop(_pin),
                child: Text(context.tr('Use this place', 'Guna tempat ini', '使用此地点')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
