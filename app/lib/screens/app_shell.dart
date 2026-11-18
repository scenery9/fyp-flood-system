import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../widgets/pill_nav.dart';
import 'centres/centres_screen.dart';
import 'home/home_screen.dart';
import 'location_question_screen.dart';
import 'more/more_screen.dart';
import 'prepare/household_setup_screen.dart';
import 'prepare/prepare_screen.dart';

/// The four tabs and the bottom menu. Shows the household form on first launch.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.needsSetup) return const HouseholdSetupScreen(firstLaunch: true);
    if (app.askLocationNow) return const LocationQuestionScreen();

    final items = [
      PillNavItem(context.tr('Home', 'Utama'), Icons.home_outlined, Icons.home),
      PillNavItem(context.tr('Prepare', 'Bersedia'), Icons.fact_check_outlined, Icons.fact_check),
      PillNavItem(context.tr('Centres', 'Pusat'), Icons.location_on_outlined, Icons.location_on),
      PillNavItem(context.tr('More', 'Lagi'), Icons.menu, Icons.menu_open),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: app.tab.index,
          children: const [HomeScreen(), PrepareScreen(), CentresScreen(), MoreScreen()],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: PillNav(
            items: items,
            index: app.tab.index,
            onTap: (i) => app.selectTab(AppTab.values[i]),
          ),
        ),
      ),
    );
  }
}
