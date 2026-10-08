/*
 * Copyright (c) 2024 The ZMK Contributors
 * Copyright (c) 2026 M0110 ZMK Driver
 *
 * SPDX-License-Identifier: MIT
 *
 * ZMK Studio's serial transport (zmk/app/src/studio/uart_rpc_transport.c),
 * interrupt-driven path only, with one change: the TX callback stops when the
 * UART stops accepting bytes instead of spinning until it does.
 *
 * On a USB CDC ACM port that spin never ends.  The callback runs on the USB
 * work queue, and the only thing that drains the CDC ring buffer is tx_work on
 * that same queue, so once a reply holds more bytes than the CDC ring has room
 * for (CONFIG_ZMK_STUDIO_RPC_TX_BUF_SIZE above CONFIG_USB_CDC_ACM_RINGBUF_SIZE,
 * or a host that has stopped reading) the cooperative work queue loops forever
 * and nothing else on the board runs again.  Stopping early is safe: the CDC
 * driver calls back once the host has taken the data, and the rest goes then.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/ring_buffer.h>

#include <zephyr/logging/log.h>
#include <zmk/studio/rpc.h>

LOG_MODULE_DECLARE(zmk_studio, CONFIG_ZMK_STUDIO_LOG_LEVEL);

BUILD_ASSERT(IS_ENABLED(CONFIG_UART_INTERRUPT_DRIVEN),
             "This transport implements only the interrupt-driven UART path");

static const struct device *const uart_dev = DEVICE_DT_GET(DT_CHOSEN(zmk_studio_rpc_uart));

static void tx_notify(struct ring_buf *tx_ring_buf, size_t written, bool msg_done,
                      void *user_data) {
    if (msg_done || (ring_buf_size_get(tx_ring_buf) > (ring_buf_capacity_get(tx_ring_buf) / 2))) {
        uart_irq_tx_enable(uart_dev);
    }
}

static int start_rx(void) {
    uart_irq_rx_enable(uart_dev);
    return 0;
}

static int stop_rx(void) {
    uart_irq_rx_disable(uart_dev);
    return 0;
}

ZMK_RPC_TRANSPORT(uart, ZMK_TRANSPORT_USB, start_rx, stop_rx, NULL, tx_notify);

static void serial_cb(const struct device *dev, void *user_data) {
    if (!uart_irq_update(uart_dev)) {
        return;
    }

    if (uart_irq_rx_ready(uart_dev)) {
        /* read until FIFO empty */
        uint32_t last_read = 0, len = 0;
        struct ring_buf *buf = zmk_rpc_get_rx_buf();
        do {
            uint8_t *buffer;
            len = ring_buf_put_claim(buf, &buffer, buf->size);
            if (len > 0) {
                last_read = uart_fifo_read(uart_dev, buffer, len);

                ring_buf_put_finish(buf, last_read);
            } else {
                LOG_ERR("Dropping incoming RPC byte, insufficient room in the RX buffer. Bump "
                        "CONFIG_ZMK_STUDIO_RPC_RX_BUF_SIZE.");
                uint8_t dummy;
                last_read = uart_fifo_read(uart_dev, &dummy, 1);
            }
        } while (last_read && last_read == len);

        zmk_rpc_rx_notify();
    }

    if (uart_irq_tx_ready(uart_dev)) {
        struct ring_buf *tx_buf = zmk_rpc_get_tx_buf();

        while (ring_buf_size_get(tx_buf) > 0) {
            uint8_t *buf;
            uint32_t claim_len = ring_buf_get_claim(tx_buf, &buf, tx_buf->size);

            if (claim_len == 0) {
                break;
            }

            int sent = uart_fifo_fill(uart_dev, buf, claim_len);

            ring_buf_get_finish(tx_buf, MAX(sent, 0));

            /* The UART is full; the driver calls back once it has drained. */
            if (sent < (int)claim_len) {
                break;
            }
        }
    }
}

static int uart_rpc_interface_init(void) {
    if (!device_is_ready(uart_dev)) {
        LOG_ERR("UART device not found!");
        return -ENODEV;
    }

    int ret = uart_irq_callback_user_data_set(uart_dev, serial_cb, NULL);

    if (ret < 0) {
        if (ret == -ENOTSUP) {
            printk("Interrupt-driven UART API support not enabled\n");
        } else if (ret == -ENOSYS) {
            printk("UART device does not support interrupt-driven API\n");
        } else {
            printk("Error setting UART callback: %d\n", ret);
        }
        return ret;
    }

    return 0;
}

SYS_INIT(uart_rpc_interface_init, POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEFAULT);
