/* One consumer exercises both foundational and desktop objects from the complete
 * installed archive. No socket, display, clipboard or device is opened. */
#include <spice_zig.h>
#include <spice_zig_source.h>
#include <assert.h>

int main(void) {
    SpiceZigWire *wire = spice_zig_wire_create(1, 64, 128, 8);
    assert(wire);
    SpiceZigDesktop *desktop = NULL;
    assert(spice_zig_desktop_create(NULL, 0, &desktop) == 0);
    SpiceZigSourceOptions options;
    spice_zig_source_options(&options);
    SpiceZigSource *source = NULL;
    assert(spice_zig_source_create(desktop, &options, &source) == 0);
    SpiceZigSourceMetrics metrics;
    assert(spice_zig_source_metrics(source, &metrics) == 0);
    assert(metrics.subscriptions == 0 && metrics.visible == 0);
    spice_zig_source_destroy(source);
    spice_zig_desktop_cancel(desktop);
    spice_zig_desktop_join(desktop);
    spice_zig_desktop_destroy(desktop);
    spice_zig_wire_destroy(wire);
    return 0;
}
