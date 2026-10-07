/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * ADC setup adapted from ZMK's battery_nrf_vddh.c (MIT, The ZMK Contributors)
 *
 * SPDX-License-Identifier: MIT
 *
 * Battery sensor for a nice!nano v2: reads VDDH like ZMK's zmk,battery-nrf-vddh,
 * then hands the reading to battery_estimator.c, which corrects for the
 * charger and uses an OCV table.  See that file for why.
 */

#define DT_DRV_COMPAT zmk_battery_vddh_ocv

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <hal/nrf_power.h>

#include "battery_estimator.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#if !NRF_POWER_HAS_USBREG
#error "zmk,battery-vddh-ocv needs the nRF52840's USB VBUS detector"
#endif

BUILD_ASSERT(DT_INST_PROP_LEN(0, ocv_capacity_table_0) == BATTERY_ESTIMATOR_OCV_POINTS,
             "ocv-capacity-table-0 must have 11 entries, 0% to 100% in 10% steps");

#define VDDHDIV 5

static const struct device *adc = DEVICE_DT_GET(DT_NODELABEL(adc));

static const struct battery_estimator_config estimator_config = {
    .ocv_uv = DT_INST_PROP(0, ocv_capacity_table_0),
    .charger_offset_uv = DT_INST_PROP(0, charger_out_offset_microvolt),
    .max_rise_mpct_per_hour =
        (int32_t)((int64_t)DT_INST_PROP(0, constant_charge_current_max_microamp) * 100000 /
                  DT_INST_PROP(0, charge_full_design_microamp_hours)),
};

/*
 * ZMK stops asking for samples while idle, but the charger offset can only be
 * measured from samples taken either side of a USB plug or unplug, and the
 * cable usually goes in while nobody is typing.  The driver therefore samples
 * on its own whenever ZMK has not asked for this long.
 */
#define BACKGROUND_SAMPLE_MS (60 * 1000)

struct vddh_ocv_data {
    struct adc_channel_cfg acc;
    struct adc_sequence as;
    int16_t adc_raw;
    struct battery_estimator est;
    /* ZMK's fetches and the background work run on different work queues. */
    struct k_mutex lock;
    struct k_work_delayable background_work;
};

/* VDDH in microvolts.  adc_raw_to_millivolts() would round to 5 mV after the x5. */
static int read_vddh_uv(struct vddh_ocv_data *data, int32_t *vddh_uv) {
    int rc = adc_read(adc, &data->as);
    data->as.calibrate = false;

    if (rc != 0) {
        LOG_ERR("Failed to read ADC: %d", rc);
        return rc;
    }

    /* Scaled by 100 first so the int32 gain inversion cannot overflow. */
    int32_t val = (int32_t)data->adc_raw * adc_ref_internal(adc) * 100;

    rc = adc_gain_invert(data->acc.gain, &val);
    if (rc != 0) {
        LOG_ERR("Failed to invert ADC gain: %d", rc);
        return rc;
    }

    *vddh_uv = (int32_t)(((int64_t)val * 10 * VDDHDIV) >> data->as.resolution);
    return 0;
}

/* Read VDDH and feed the estimator.  Call with data->lock held. */
static int sample(struct vddh_ocv_data *data) {
    int32_t vddh_uv;
    int rc = read_vddh_uv(data, &vddh_uv);

    if (rc != 0) {
        return rc;
    }

    bool on_usb = nrf_power_usbregstatus_vbusdet_get(NRF_POWER);
    int32_t offset_before_uv = data->est.offset_uv;

    battery_estimator_update(&data->est, vddh_uv, on_usb, k_uptime_get());

    if (data->est.offset_uv != offset_before_uv) {
        LOG_INF("Measured charger offset: %d mV (was %d mV)", data->est.offset_uv / 1000,
                offset_before_uv / 1000);
    }

    LOG_DBG("VDDH %d mV%s => cell %d mV => %d.%03d%%", vddh_uv / 1000, on_usb ? " (USB)" : "",
            data->est.cell_uv / 1000, data->est.soc_mpct / 1000, data->est.soc_mpct % 1000);

    return 0;
}

static void background_sample(struct k_work *work) {
    struct k_work_delayable *dwork = k_work_delayable_from_work(work);
    struct vddh_ocv_data *data = CONTAINER_OF(dwork, struct vddh_ocv_data, background_work);

    k_mutex_lock(&data->lock, K_FOREVER);

    if (!data->est.primed || k_uptime_get() - data->est.at_ms >= BACKGROUND_SAMPLE_MS) {
        sample(data);
    }

    k_mutex_unlock(&data->lock);

    k_work_schedule(&data->background_work, K_MSEC(BACKGROUND_SAMPLE_MS));
}

static int vddh_ocv_sample_fetch(const struct device *dev, enum sensor_channel chan) {
    if (chan != SENSOR_CHAN_GAUGE_VOLTAGE && chan != SENSOR_CHAN_GAUGE_STATE_OF_CHARGE &&
        chan != SENSOR_CHAN_ALL) {
        LOG_DBG("Selected channel is not supported: %d.", chan);
        return -ENOTSUP;
    }

    struct vddh_ocv_data *data = dev->data;

    k_mutex_lock(&data->lock, K_FOREVER);
    int rc = sample(data);
    k_mutex_unlock(&data->lock);

    return rc;
}

static int vddh_ocv_channel_get(const struct device *dev, enum sensor_channel chan,
                                struct sensor_value *val) {
    const struct vddh_ocv_data *data = dev->data;

    switch (chan) {
    case SENSOR_CHAN_GAUGE_VOLTAGE:
        val->val1 = data->est.cell_uv / 1000000;
        val->val2 = data->est.cell_uv % 1000000;
        break;

    case SENSOR_CHAN_GAUGE_STATE_OF_CHARGE:
        val->val1 = CLAMP((data->est.soc_mpct + 500) / 1000, 0, 100);
        val->val2 = 0;
        break;

    default:
        return -ENOTSUP;
    }

    return 0;
}

static const struct sensor_driver_api vddh_ocv_api = {
    .sample_fetch = vddh_ocv_sample_fetch,
    .channel_get = vddh_ocv_channel_get,
};

static int vddh_ocv_init(const struct device *dev) {
    struct vddh_ocv_data *data = dev->data;

    for (int i = 1; i < BATTERY_ESTIMATOR_OCV_POINTS; i++) {
        if (estimator_config.ocv_uv[i] <= estimator_config.ocv_uv[i - 1]) {
            LOG_ERR("ocv-capacity-table-0 must be strictly ascending");
            return -EINVAL;
        }
    }

    if (!device_is_ready(adc)) {
        LOG_ERR("ADC device is not ready %s", adc->name);
        return -ENODEV;
    }

    battery_estimator_init(&data->est, &estimator_config);

    data->as = (struct adc_sequence){
        .channels = BIT(0),
        .buffer = &data->adc_raw,
        .buffer_size = sizeof(data->adc_raw),
        .oversampling = 4,
        .calibrate = true,
        .resolution = 12,
    };

    data->acc = (struct adc_channel_cfg){
        .gain = ADC_GAIN_1_2,
        .reference = ADC_REF_INTERNAL,
        .acquisition_time = ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40),
        .input_positive = SAADC_CH_PSELN_PSELN_VDDHDIV5,
    };

    int rc = adc_channel_setup(adc, &data->acc);
    LOG_DBG("VDDHDIV5 setup returned %d", rc);

    if (rc != 0) {
        return rc;
    }

    k_mutex_init(&data->lock);
    k_work_init_delayable(&data->background_work, background_sample);
    k_work_schedule(&data->background_work, K_MSEC(BACKGROUND_SAMPLE_MS));

    return 0;
}

static struct vddh_ocv_data vddh_ocv_data;

DEVICE_DT_INST_DEFINE(0, &vddh_ocv_init, NULL, &vddh_ocv_data, NULL, POST_KERNEL,
                      CONFIG_SENSOR_INIT_PRIORITY, &vddh_ocv_api);
