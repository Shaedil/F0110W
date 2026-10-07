/*
 * Host-side tests for the battery estimator.
 */

#include <stdio.h>
#include <stdlib.h>

#include "../config/drivers/sensor/battery_estimator.h"

#define MINUTE_MS (60LL * 1000)

static const struct battery_estimator_config config = {
    .ocv_uv = {3270000, 3690000, 3730000, 3770000, 3800000, 3840000, 3870000, 3950000, 4020000,
               4110000, 4200000},
    .charger_offset_uv = 225000,
    .max_rise_mpct_per_hour = 11000, /* 1.1 A into 10 Ah */
};

static int failures;

#define EXPECT(cond, ...)                                                                          \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL %s:%d: ", __func__, __LINE__);                                            \
            printf(__VA_ARGS__);                                                                   \
            printf("\n");                                                                          \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* Feed one sample per minute for `minutes`, starting at *t. */
static void run(struct battery_estimator *est, int32_t vddh_uv, int on_usb, int minutes,
                int64_t *t) {
    for (int i = 0; i < minutes; i++) {
        battery_estimator_update(est, vddh_uv, on_usb, *t);
        *t += MINUTE_MS;
    }
}

static void test_ocv_lookup(void) {
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 3000000) == 0, "below table");
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 3270000) == 0, "0%% point");
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 3840000) == 50000, "50%% point");
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 3820000) == 45000, "midway 40-50%%");
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 4200000) == 100000, "100%% point");
    EXPECT(battery_estimator_ocv_to_mpct(config.ocv_uv, 4300000) == 100000, "above table");
}

static void test_first_sample_is_reported_directly(void) {
    struct battery_estimator est;
    battery_estimator_init(&est, &config);

    battery_estimator_update(&est, 3840000, false, 0);
    EXPECT(est.soc_mpct == 50000, "soc %d", est.soc_mpct);
}

static void test_plug_in_does_not_jump(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3750000, false, 10, &t);
    int32_t before = est.soc_mpct;

    /* bq24072 lifts OUT by 240 mV on this board; nothing else changes. */
    run(&est, 3990000, true, 30, &t);

    EXPECT(est.offset_measured && est.offset_uv == 240000, "offset %d", est.offset_uv);
    EXPECT(est.soc_mpct == before, "soc %d, was %d", est.soc_mpct, before);
}

static void test_plug_in_with_charge_current(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3800000, false, 10, &t);
    int32_t before = est.soc_mpct;

    /* bq24072's 225 mV plus about 1.1 A through the cell, JST and wiring. */
    run(&est, 4130000, true, 5, &t);

    EXPECT(est.offset_measured && est.offset_uv == 330000, "offset %d", est.offset_uv);
    EXPECT(est.soc_mpct == before, "soc %d, was %d", est.soc_mpct, before);
}

static void test_unplug_measures_offset(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 4060000, true, 10, &t);
    run(&est, 3800000, false, 1, &t);

    EXPECT(est.offset_measured && est.offset_uv == 260000, "offset %d", est.offset_uv);
}

static void test_stale_edge_keeps_default_offset(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3750000, false, 1, &t);
    t += 30 * MINUTE_MS; /* idle: ZMK stops sampling */
    run(&est, 3990000, true, 1, &t);

    EXPECT(!est.offset_measured && est.offset_uv == 225000, "offset %d", est.offset_uv);
}

static void test_implausible_offset_is_rejected(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3700000, false, 1, &t);
    run(&est, 4300000, true, 1, &t);
    EXPECT(!est.offset_measured, "600 mV step accepted as offset");

    /* Under VBAT 3.2 V the charger clamps OUT at 3.4 V. */
    battery_estimator_init(&est, &config);
    run(&est, 3150000, false, 1, &t);
    run(&est, 3400000, true, 1, &t);
    EXPECT(!est.offset_measured, "clamped OUT accepted as offset");
}

static void test_load_rebound_is_ignored(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3800000, false, 10, &t);
    int32_t before = est.soc_mpct;

    /* Boost power-save drops the M0110's load: +8 mV, about 2.7%. */
    run(&est, 3808000, false, 30, &t);
    EXPECT(est.soc_mpct == before, "soc %d, was %d", est.soc_mpct, before);
}

static void test_charge_rise_is_rate_limited(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3750000, false, 10, &t);
    int32_t before = est.soc_mpct;

    /* The bq25185's 1 A lifts the terminal voltage to the 70% point at once. */
    run(&est, 3950000, false, 60, &t);
    int32_t rise = est.soc_mpct - before;

    EXPECT(rise > 9000 && rise <= 11000, "rose %d mpct in an hour", rise);
}

static void test_rise_completes_to_full(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3750000, false, 10, &t);
    run(&est, 4200000, false, 10 * 60, &t);

    EXPECT(est.soc_mpct == 100000, "soc %d after a full charge", est.soc_mpct);
}

static void test_discharge_follows(void) {
    struct battery_estimator est;
    int64_t t = 0;
    battery_estimator_init(&est, &config);

    run(&est, 3870000, false, 10, &t);
    run(&est, 3770000, false, 60, &t);

    EXPECT(est.soc_mpct >= 30000 && est.soc_mpct < 30500, "soc %d", est.soc_mpct);
}

int main(void) {
    test_ocv_lookup();
    test_first_sample_is_reported_directly();
    test_plug_in_does_not_jump();
    test_plug_in_with_charge_current();
    test_unplug_measures_offset();
    test_stale_edge_keeps_default_offset();
    test_implausible_offset_is_rejected();
    test_load_rebound_is_ignored();
    test_charge_rise_is_rate_limited();
    test_rise_completes_to_full();
    test_discharge_follows();

    if (failures) {
        printf("%d battery estimator check(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    printf("battery estimator: all checks passed\n");
    return EXIT_SUCCESS;
}
