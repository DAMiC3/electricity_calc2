// Unit tests for the calculation and parsing logic in lib/main.dart.
// Run with:  flutter test
import 'package:electricity_calc2/main.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------- helpers ----------
RegionTariff tariff(
  String key,
  int year,
  List<List<num?>> blocks, {
  double fixed = 0,
  double? split,
  String type = 'residential',
}) =>
    RegionTariff(
      regionKey: key,
      displayName: key,
      customerType: type,
      startDate: DateTime(year, 7, 1),
      endDate: DateTime(year + 1, 6, 30),
      fixedMonthly: fixed,
      fixedSplitBelow: split,
      blocks: [
        for (final b in blocks)
          TariffBlock(
              from: b[0]!.toInt(), to: b[1]?.toInt(), rate: b[2]!.toDouble()),
      ],
    );

TransactionRecord tx(String id, DateTime date, double money,
        {String region = 'tshwane', double actual = 100}) =>
    TransactionRecord(
        id: id,
        regionKey: region,
        date: date,
        money: money,
        actualKwh: actual,
        expectedKwh: 0);

// Tshwane incl-VAT rates (ex-VAT gazette figure x 1.15).
final tsh2021 = tariff('tshwane', 2021, [
  [1, 100, 1.9513 * 1.15],
  [101, 400, 2.2835 * 1.15],
  [401, 650, 2.4879 * 1.15],
  [651, null, 2.6820 * 1.15],
]);
final tsh2025 = tariff('tshwane', 2025, [
  [1, 100, 2.9790 * 1.15],
  [101, 400, 3.4864 * 1.15],
  [401, 650, 3.7984 * 1.15],
  [651, null, 4.0948 * 1.15],
]);
final tsh2026 = tariff('tshwane', 2026, [
  [1, 100, 3.2412 * 1.15],
  [101, 400, 3.7932 * 1.15],
  [401, 650, 4.1326 * 1.15],
  [651, null, 4.4551 * 1.15],
]);
final jhb2025 = tariff(
    'joburg',
    2025,
    [
      [1, 350, 2.6645 * 1.15],
      [351, 500, 3.0564 * 1.15],
      [501, null, (3.4826 + 0.06) * 1.15],
    ],
    fixed: 230,
    split: 400);
final ekFlat2025 = tariff(
    'ekurhuleni_flat',
    2025,
    [
      [1, null, 3.3722 * 1.15],
    ],
    fixed: 109.78 * 1.15);

void main() {
  group('Calc.expectedKwhFromMoneyAt (inclining blocks)', () {
    test('R500 at the start of the month in Tshwane 2025/26', () {
      final kwh = Calc.expectedKwhFromMoneyAt(500, tsh2025.blocks, 0);
      final block1Cost = 100 * 2.9790 * 1.15;
      final expected = 100 + (500 - block1Cost) / (3.4864 * 1.15);
      expect(kwh, closeTo(expected, 1e-9));
    });

    test('continues from the month-to-date position', () {
      // Already bought 100 kWh -> everything is in block 2.
      final kwh = Calc.expectedKwhFromMoneyAt(100, tsh2025.blocks, 100);
      expect(kwh, closeTo(100 / (3.4864 * 1.15), 1e-9));
    });

    test('splitting a purchase in two gives the same total', () {
      final whole = Calc.expectedKwhFromMoneyAt(1500, tsh2025.blocks, 0);
      final a = Calc.expectedKwhFromMoneyAt(600, tsh2025.blocks, 0);
      final b = Calc.expectedKwhFromMoneyAt(900, tsh2025.blocks, a);
      expect(a + b, closeTo(whole, 1e-9));
    });

    test('breakdown adds up to the money and the kWh', () {
      final bd = Calc.breakdownForPurchase(2000, tsh2025.blocks, 37.5);
      final kwh = Calc.expectedKwhFromMoneyAt(2000, tsh2025.blocks, 37.5);
      expect(bd.fold<double>(0, (s, b) => s + b.cost), closeTo(2000, 1e-9));
      expect(bd.fold<double>(0, (s, b) => s + b.kwh), closeTo(kwh, 1e-9));
    });
  });

  group('TariffManager.findRegionForDate (the 2021-rates bug)', () {
    final all = [tsh2021, tsh2025];

    test('date inside a period uses that period', () {
      expect(
          TariffManager.findRegionForDate(all, 'tshwane', DateTime(2025, 9, 1)),
          same(tsh2025));
      expect(
          TariffManager.findRegionForDate(all, 'tshwane', DateTime(2021, 9, 1)),
          same(tsh2021));
    });

    test('after the last period it uses the LATEST tariff, never 2021', () {
      // Before the fix this returned the 2021/22 rates.
      expect(
          TariffManager.findRegionForDate(all, 'tshwane', DateTime(2026, 11, 18)),
          same(tsh2025));
    });

    test('the last day of a period counts for the whole day', () {
      final lateOnLastDay = DateTime(2026, 6, 30, 14, 30);
      expect(TariffManager.findRegionForDate([tsh2025, tsh2026], 'tshwane', lateOnLastDay),
          same(tsh2025));
      expect(
          TariffManager.findRegionForDate(
              [tsh2025, tsh2026], 'tshwane', DateTime(2026, 7, 1, 0, 1)),
          same(tsh2026));
    });

    test('before the first period it uses the earliest', () {
      expect(
          TariffManager.findRegionForDate(all, 'tshwane', DateTime(2020, 1, 1)),
          same(tsh2021));
    });

    test('unknown region returns null', () {
      expect(TariffManager.findRegionForDate(all, 'durban', DateTime(2025)), isNull);
    });
  });

  group('TariffManager helpers', () {
    test('currentPerRegion ignores a future year that has not started', () {
      final list = [tsh2025, tsh2026, jhb2025];
      final now = TariffManager.currentPerRegion(list, DateTime(2026, 3, 1));
      expect(now.map((r) => r.regionKey), ['tshwane', 'joburg']);
      expect(now.first, same(tsh2025));
      final later = TariffManager.currentPerRegion(list, DateTime(2026, 8, 1));
      expect(later.first, same(tsh2026));
    });

    test('commercial falls back to residential when a region has none', () {
      final com = tariff('joburg', 2025, [
        [1, null, 5.0]
      ], type: 'commercial');
      final picked = TariffManager.selectForType([tsh2025, jhb2025, com], 'commercial');
      expect(picked, containsAll([tsh2025, com]));
      expect(picked, isNot(contains(jhb2025)));
      expect(TariffManager.selectForType([tsh2025, jhb2025, com], 'residential'),
          [tsh2025, jhb2025]);
    });

    test('regionsFromRows groups blocks and attaches the fixed charge', () {
      final rows = [
        {'region_key': 'joburg', 'display_name': 'City of Johannesburg', 'customer_type': 'residential',
         'start_date': '2025-07-01', 'end_date': '2026-06-30', 'tier_from': 501, 'tier_to': null, 'rate_incl_vat': 4.07399},
        {'region_key': 'joburg', 'display_name': 'City of Johannesburg', 'customer_type': 'residential',
         'start_date': '2025-07-01', 'end_date': '2026-06-30', 'tier_from': 1, 'tier_to': 350, 'rate_incl_vat': '3.064175'},
        {'region_key': 'joburg', 'display_name': 'City of Johannesburg', 'customer_type': 'residential',
         'start_date': '2025-07-01', 'end_date': '2026-06-30', 'tier_from': 351, 'tier_to': 500, 'rate_incl_vat': 3.51486},
        {'region_key': 'tshwane', 'display_name': 'City of Tshwane', 'customer_type': 'residential',
         'start_date': '2025-07-01', 'end_date': null, 'tier_from': 1, 'tier_to': null, 'rate_incl_vat': 3},
      ];
      final fixed = [
        {'region_key': 'joburg', 'customer_type': 'residential', 'start_date': '2025-07-01',
         'amount_incl_vat': 230.0, 'split_below_incl_vat': 400},
      ];
      final out = TariffManager.regionsFromRows(rows, fixedRows: fixed);
      expect(out.length, 2);
      final j = out.first;
      expect(j.regionKey, 'joburg');
      expect(j.blocks.map((b) => b.from), [1, 351, 501]); // sorted
      expect(j.blocks.first.rate, closeTo(3.064175, 1e-12)); // numeric string ok
      expect(j.endDate, DateTime(2026, 6, 30));
      expect(j.fixedMonthly, 230);
      expect(j.fixedSplitBelow, 400);
      expect(out[1].fixedMonthly, 0);
      expect(out[1].endDate, isNull);
    });

    test('cached JSON round-trip keeps everything; old cache = residential', () {
      final back = RegionTariff.fromJson(jhb2025.toJson());
      expect(back.fixedMonthly, 230);
      expect(back.fixedSplitBelow, 400);
      expect(back.customerType, 'residential');
      expect(back.startDate, jhb2025.startDate);
      expect(back.endDate, jhb2025.endDate);
      expect(back.blocks.length, 3);
      final old = RegionTariff.fromJson({
        'regionKey': 'tshwane',
        'displayName': 'City of Tshwane',
        'startDate': '2025-07-01',
        'endDate': '2026-06-30',
        'blocks': [
          {'from': 1, 'to': null, 'rate': 3.0}
        ],
      });
      expect(old.customerType, 'residential');
      expect(old.fixedMonthly, 0);
    });
  });

  group('Calc.runPurchases (month-cumulative, fixed charges)', () {
    test('blocks continue within a month and restart next month', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 500),
        tx('b', DateTime(2025, 9, 15), 500),
        tx('c', DateTime(2025, 10, 1), 500),
      ];
      final r = Calc.runPurchases(list, [tsh2025]);
      expect(r[0].kwhBefore, 0);
      expect(r[1].kwhBefore, closeTo(r[0].tx.expectedKwh, 1e-9));
      expect(r[2].kwhBefore, 0); // new month
      expect(r[2].tx.expectedKwh, closeTo(r[0].tx.expectedKwh, 1e-9));
      expect(r[1].tx.expectedKwh, lessThan(r[0].tx.expectedKwh)); // higher block
    });

    test('regions are tracked separately', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 500),
        tx('b', DateTime(2025, 9, 2), 500, region: 'joburg'),
      ];
      final r = Calc.runPurchases(list, [tsh2025, jhb2025]);
      expect(r[1].kwhBefore, 0);
      expect(r[1].tariff, same(jhb2025));
    });

    test('Joburg fixed charge: R300 is split half/half (City FAQ example)', () {
      final r = Calc.runPurchases([tx('a', DateTime(2025, 9, 1), 300, region: 'joburg')], [jhb2025]);
      expect(r[0].fixedCharge, closeTo(150, 1e-9));
      expect(r[0].energyMoney, closeTo(150, 1e-9));
      // FAQ: R300 -> about R130 (ex VAT) to the charge, R130 to electricity.
      expect(r[0].fixedCharge / 1.15, closeTo(130.43, 0.01));
      expect(r[0].tx.expectedKwh, closeTo(150 / (2.6645 * 1.15), 1e-9));
    });

    test('Joburg fixed charge: big purchase pays it first, then nothing more that month', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 1000, region: 'joburg'),
        tx('b', DateTime(2025, 9, 20), 1000, region: 'joburg'),
        tx('c', DateTime(2025, 10, 2), 1000, region: 'joburg'),
      ];
      final r = Calc.runPurchases(list, [jhb2025]);
      expect(r[0].fixedCharge, closeTo(230, 1e-9));
      expect(r[1].fixedCharge, 0);
      expect(r[2].fixedCharge, closeTo(230, 1e-9)); // new month
    });

    test('Joburg: small purchase then a big one pays only the remainder', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 100, region: 'joburg'), // 50 to charge
        tx('b', DateTime(2025, 9, 2), 500, region: 'joburg'), // 180 to charge
      ];
      final r = Calc.runPurchases(list, [jhb2025]);
      expect(r[0].fixedCharge, closeTo(50, 1e-9));
      expect(r[1].fixedCharge, closeTo(180, 1e-9));
    });

    test('Ekurhuleni Tariff B: no split rule, the charge comes first', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 50, region: 'ekurhuleni_flat'),
        tx('b', DateTime(2025, 9, 3), 500, region: 'ekurhuleni_flat'),
      ];
      final r = Calc.runPurchases(list, [ekFlat2025]);
      expect(r[0].fixedCharge, 50);
      expect(r[0].tx.expectedKwh, 0);
      expect(r[1].fixedCharge, closeTo(109.78 * 1.15 - 50, 1e-9));
    });

    test('tariffs without a fixed charge are unaffected', () {
      final r = Calc.runPurchases([tx('a', DateTime(2025, 9, 1), 500)], [tsh2025]);
      expect(r[0].fixedCharge, 0);
      expect(r[0].tx.expectedKwh,
          closeTo(Calc.expectedKwhFromMoneyAt(500, tsh2025.blocks, 0), 1e-12));
    });

    test('Store.computeExpected matches runPurchases', () {
      final list = [
        tx('a', DateTime(2025, 9, 1), 300, region: 'joburg'),
        tx('b', DateTime(2025, 9, 2), 900, region: 'joburg'),
      ];
      final a = Store.computeExpected(list, [jhb2025]).map((t) => t.expectedKwh).toList();
      final b = Calc.runPurchases(list, [jhb2025]).map((p) => p.tx.expectedKwh).toList();
      expect(a, b);
    });

    test('purchases at the same moment keep their order (no re-sorting)', () {
      final t = DateTime(2025, 9, 1);
      final list = [tx('first', t, 400), tx('second', t, 400), tx('third', t, 400)];
      final r = Calc.runPurchases(list, [tsh2025]);
      expect(r.map((p) => p.tx.id), ['first', 'second', 'third']);
      expect(r[0].kwhBefore, 0);
    });
  });

  group('Calc.fixedChargeTaken', () {
    test('rules', () {
      expect(Calc.fixedChargeTaken(1000, 230, 400), 230);
      expect(Calc.fixedChargeTaken(399, 230, 400), 199.5);
      expect(Calc.fixedChargeTaken(400, 230, 400), 230);
      expect(Calc.fixedChargeTaken(100, 30, 400), 30);
      expect(Calc.fixedChargeTaken(100, 0, 400), 0);
      expect(Calc.fixedChargeTaken(100, 230, null), 100);
    });
  });

  group('TransactionRecord.wallClockFrom', () {
    test('keeps the saved wall-clock time as a local DateTime', () {
      final d = TransactionRecord.wallClockFrom('2026-03-03T08:45:10.228943+00:00');
      expect(d.isUtc, isFalse);
      expect([d.year, d.month, d.day, d.hour, d.minute, d.second], [2026, 3, 3, 8, 45, 10]);
      // compares correctly with a date picked in the app
      expect(d.isAfter(DateTime(2026, 3, 3, 8, 0)), isTrue);
      expect(d.isBefore(DateTime(2026, 3, 3, 9, 0)), isTrue);
    });

    test('round-trips to the same text the app writes', () {
      final d = TransactionRecord.wallClockFrom('2025-10-31T13:39:46.018708+00:00');
      expect(d.toIso8601String(), '2025-10-31T13:39:46.018708');
    });
  });

  group('SmsParser', () {
    final now = DateTime(2026, 11, 18, 10);

    test('typical token SMS', () {
      final r = SmsParser.parse(
          'Prepaid electricity. Meter 04123456789 Token 1234 5678 9012 3456 7890 '
          'R500.00 152.3kWh 2026-11-17 14:22',
          now: now);
      expect(r.amount, 500);
      expect(r.kwh, 152.3);
      expect(r.date, DateTime(2026, 11, 17, 14, 22));
    });

    test('meter number is never taken as the amount (old bug)', () {
      final r = SmsParser.parse('Your meter 12345678901 received 152.3kWh for R200.00', now: now);
      expect(r.amount, 200);
      expect(r.kwh, 152.3);
    });

    test('labels and thousands separators', () {
      final r = SmsParser.parse('Total: R1,500.00 Units: 380.5', now: now);
      expect(r.amount, 1500);
      expect(r.kwh, 380.5);
    });

    test('comma decimals', () {
      expect(SmsParser.parseAmount('Amount R50,50'), 50.5);
      expect(SmsParser.parseKwh('12,5 kWh'), 12.5);
    });

    test('a date next to "Paid" is not the amount', () {
      final r = SmsParser.parse('Paid 15/10/2026 R300', now: now);
      expect(r.amount, 300);
      expect(r.date, DateTime(2026, 10, 15));
    });

    test('ZAR and units', () {
      final r = SmsParser.parse('ZAR250 for 60 units', now: now);
      expect(r.amount, 250);
      expect(r.kwh, 60);
    });

    test('kWh figure is not used as the amount', () {
      expect(SmsParser.parseAmount('You received 152.30 kWh'), isNull);
    });

    test('simple formats the old parser already handled still work', () {
      expect(SmsParser.parseAmount('R 100'), 100);
      expect(SmsParser.parseAmount('R100'), 100);
      expect(SmsParser.parseAmount('Amount: 200'), 200);
      expect(SmsParser.parseAmount('Amount 200.50'), 200.5);
      expect(SmsParser.parseAmount('500 Rand'), 500);
      expect(SmsParser.parseAmount('Rand 75'), 75);
      expect(SmsParser.parseAmount('R100.00 incl R13.04 VAT'), 100);
      expect(SmsParser.parseAmount('paid 99.90 thanks'), 99.9);
      expect(SmsParser.parseKwh('kWh: 45.6'), 45.6);
      expect(SmsParser.parseKwh('kWh 45.6'), 45.6);
      expect(SmsParser.parseKwh('Units purchased: 45.6'), 45.6);
      expect(SmsParser.parseKwh('45.6 units'), 45.6);
      expect(SmsParser.parseKwh('45.6kWh'), 45.6);
      expect(SmsParser.parseKwh('KWH45.6'), 45.6);
      expect(SmsParser.parseDate('28/10/2025', now: now), DateTime(2025, 10, 28));
      expect(SmsParser.parseDate('2025/10/28', now: now), DateTime(2025, 10, 28));
      expect(SmsParser.parseDate('28.10.2025', now: now), DateTime(2025, 10, 28));
    });

    test('nothing found', () {
      final r = SmsParser.parse('Hello there', now: now);
      expect(r.amount, isNull);
      expect(r.kwh, isNull);
      expect(r.date, isNull);
    });

    test('dates: day-first, month names, US order, future rejected', () {
      expect(SmsParser.parseDate('on 28 Oct 2025', now: now), DateTime(2025, 10, 28));
      expect(SmsParser.parseDate('Oct 5, 2025', now: now), DateTime(2025, 10, 5));
      expect(SmsParser.parseDate('01/02/2026', now: now), DateTime(2026, 2, 1));
      expect(SmsParser.parseDate('10/28/2025', now: now), DateTime(2025, 10, 28));
      expect(SmsParser.parseDate('2027-01-01', now: now), isNull); // future
      expect(SmsParser.parseDate('2019-01-01', now: now), isNull); // too old for the picker
    });
  });
}
