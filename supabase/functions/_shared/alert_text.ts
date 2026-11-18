// Notification wording in English, Malay and Chinese. Level names match the app.

export interface DueAlert {
  rule_id: string;
  user_id: string;
  fcm_token: string;
  language: string;
  station_code: string;
  station_name: string;
  kind: 'risk' | 'level';
  level: 'normal' | 'alert' | 'warning' | 'danger';
  level_m: number;
  alert_level_m: number | null;
  reason: 'first' | 'escalated' | 'danger_repeat';
}

const LEVELS: Record<string, Record<string, string>> = {
  en: { normal: 'Normal', alert: 'Alert', warning: 'Warning', danger: 'Danger' },
  ms: { normal: 'Normal', alert: 'Waspada', warning: 'Amaran', danger: 'Bahaya' },
  zh: { normal: '正常', alert: '警戒', warning: '警告', danger: '危险' },
};
const RANK: Record<string, number> = { normal: 0, alert: 1, warning: 2, danger: 3 };

const m2 = (v: number) => v.toFixed(2);

/** One phone and one station may have two rules due at once (level and height): send one message. */
export function groupDue(rows: DueAlert[]): DueAlert[][] {
  const groups = new Map<string, DueAlert[]>();
  for (const r of rows) {
    const k = `${r.user_id}|${r.station_code}`;
    const g = groups.get(k);
    if (g) g.push(r);
    else groups.set(k, [r]);
  }
  return [...groups.values()];
}

/** Title and body for one group. Prefers the risk-level rule; else the height rule. */
export function alertText(group: DueAlert[]): { title: string; body: string } {
  const risk = group.filter((r) => r.kind === 'risk').sort((a, b) => RANK[b.level] - RANK[a.level])[0];
  const r = risk ?? group[0];
  const lang = r.language in LEVELS ? r.language : 'en';
  const lvl = LEVELS[lang][r.level] ?? r.level;
  const name = r.station_name;
  const now = m2(r.level_m);
  if (lang === 'ms') {
    const title = `Amaran banjir: ${name}`;
    if (r.kind === 'level') {
      return { title, body: `Paras sungai mencecah ${now} m (amaran anda: ${m2(r.alert_level_m ?? 0)} m). Tahap: ${lvl}.` };
    }
    return {
      title,
      body: r.reason === 'danger_repeat'
        ? `Paras sungai masih di tahap ${lvl} (${now} m). Ikut arahan JPS dan NADMA.`
        : `Paras sungai kini di tahap ${lvl} (${now} m). Ikut arahan JPS dan NADMA.`,
    };
  }
  if (lang === 'zh') {
    const title = `洪水警报：${name}`;
    if (r.kind === 'level') {
      return { title, body: `河流水位已达 ${now} 米（您设定的警报：${m2(r.alert_level_m ?? 0)} 米）。级别：${lvl}。` };
    }
    return {
      title,
      body: r.reason === 'danger_repeat'
        ? `河流水位仍处于${lvl}级（${now} 米）。请遵从JPS和NADMA的指示。`
        : `河流水位已达${lvl}级（${now} 米）。请遵从JPS和NADMA的指示。`,
    };
  }
  const title = `Flood alert: ${name}`;
  if (r.kind === 'level') {
    return { title, body: `River has reached ${now} m (your alert: ${m2(r.alert_level_m ?? 0)} m). Level: ${lvl}.` };
  }
  return {
    title,
    body: r.reason === 'danger_repeat'
      ? `River is still at ${lvl} level (${now} m). Follow JPS and NADMA instructions.`
      : `River is at ${lvl} level (${now} m). Follow JPS and NADMA instructions.`,
  };
}
