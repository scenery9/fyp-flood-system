/// Public entry point. The Flutter app imports only this file:
///   import 'package:flood_core/flood_core.dart';
library;

export 'src/data/followed_store.dart';
export 'src/data/sample_station_repository.dart';
export 'src/data/station_repository.dart';
export 'src/errors.dart';
export 'src/models/risk_level.dart';
export 'src/models/station.dart';
export 'src/models/station_reading.dart';
export 'src/models/station_status.dart';
export 'src/risk/risk_calculator.dart';
export 'src/services/followed_areas_service.dart';
export 'src/services/home_service.dart';
export 'src/services/monitoring_service.dart';
export 'src/services/share_formatter.dart';
export 'src/services/station_list_service.dart';
export 'src/services/warning_service.dart';
export 'src/util/geo.dart';

// Round 2: public act/personalise, staff portal, assistant
export 'src/data/table.dart';
export 'src/models/alert_rule.dart';
export 'src/models/app_settings.dart';
export 'src/models/damage_report.dart';
export 'src/models/district.dart';
export 'src/models/evacuation_point.dart';
export 'src/models/headcount.dart';
export 'src/models/resources.dart';
export 'src/models/staff.dart';
export 'src/services/access_control.dart';
export 'src/services/alert_service.dart';
export 'src/services/assistant_service.dart';
export 'src/services/damage_report_service.dart';
export 'src/services/evacuation_service.dart';
export 'src/services/guidance_service.dart';
export 'src/services/headcount_service.dart';
export 'src/services/resource_service.dart';
export 'src/services/settings_service.dart';
export 'src/services/staff_account_service.dart';
export 'src/services/staff_overview_service.dart';

// Round 3: routing, map data, forecast
export 'src/models/forecast.dart';
export 'src/models/route.dart';
export 'src/services/forecast_service.dart';
export 'src/services/map_service.dart';
export 'src/services/routing_service.dart';

// Round 4: security
export 'src/services/household_lock_service.dart';

// Round 5: household profile and personalised preparation checklist
export 'src/models/household_profile.dart';
export 'src/services/preparedness_service.dart';

// Round 6: staff areas, live data from Supabase, push alerts, safe routing
export 'src/data/live_station_repository.dart';
export 'src/data/supabase_api.dart';
export 'src/services/push_alert_service.dart';

// Round 7: easier alerts, offline route guide, public reports and headcount
export 'src/services/alert_guide.dart';
export 'src/services/rain_source.dart';
export 'src/services/river_source.dart';
export 'src/services/public_reports_service.dart';
export 'src/services/route_guide.dart';
export 'src/services/location_consent.dart';

// Round 8: relief centres from places/centres.csv (Supabase), Melaka
export 'src/data/live_centres.dart';
