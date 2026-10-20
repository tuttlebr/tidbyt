load("render.star", "render")
load("http.star", "http")
load("math.star", "math")
load("encoding/json.star", "json")
load("schema.star", "schema")

PROMETHEUS_URL = "http://192.168.1.234:30500"
# One snapshot; absent temperature does not prevent power from being returned.
QUERY = (
    'label_replace(sum(DCGM_FI_DEV_POWER_USAGE), "kind", "power", "", "")' +
    ' or label_replace(max(DCGM_FI_DEV_GPU_TEMP), "kind", "temperature", "", "")' +
    ' or label_replace(count(DCGM_FI_DEV_POWER_USAGE), "kind", "count", "", "")'
)
FONT = "6x13"

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "prometheus_url",
                name = "Prometheus URL",
                desc = "Base URL of your Prometheus server.",
                icon = "wifi",
                default = PROMETHEUS_URL,
            ),
            schema.Text(
                id = "expected_gpu_count",
                name = "Expected GPU count",
                desc = "Use 0 to disable the check for incomplete totals.",
                icon = "memory",
                default = "0",
            ),
        ],
    )

def number(value):
    """Parse finite numeric telemetry without raising on bad input."""
    if type(value) not in ["string", "int", "float"]:
        return None
    # JSON's numeric grammar rejects NaN/Inf and overflow without throwing.
    result = json.decode(str(value), default = None)
    if type(result) not in ["int", "float"]:
        return None
    return result

def read_metrics(payload):
    if type(payload) != "dict" or payload.get("status") != "success":
        return {}
    data = payload.get("data")
    if type(data) != "dict" or data.get("resultType") != "vector":
        return {}
    rows = data.get("result")
    if type(rows) != "list":
        return {}
    values = {}
    for row in rows:
        if type(row) != "dict":
            continue
        metric = row.get("metric")
        value = row.get("value")
        if type(metric) != "dict" or type(value) != "list" or len(value) != 2:
            continue
        kind = metric.get("kind")
        if kind in ["power", "temperature", "count"]:
            values[kind] = number(value[1])
    return values

def main(config):
    values = {}
    if config.get("offline") != "true":
        response = http.get(
            config.get("prometheus_url", PROMETHEUS_URL).rstrip("/") + "/api/v1/query",
            params = {"query": QUERY},
        )
        if response.status_code == 200:
            values = read_metrics(json.decode(response.body(), default = None))
        else:
            print("Prometheus HTTP status:", response.status_code)

    watts = values.get("power")
    temp = values.get("temperature")
    count = values.get("count")
    expected = number(config.get("expected_gpu_count", "0"))
    text = "Unavailable"
    text_color = "#f5a623"
    value_font = "tb-8"

    if watts == None or watts < 0 or count == None or count <= 0 or count != math.floor(count):
        print("telemetry unavailable: missing or invalid power/count")
    elif expected == None or expected < 0 or expected != math.floor(expected):
        print("telemetry unavailable: invalid expected_gpu_count")
    elif expected > 0 and count != expected:
        text = "Incomplete"
        print("telemetry incomplete: expected", expected, "GPU series; received", count)
    else:
        watts = int(math.round(watts))
        text = "{} watts".format(watts)
        value_font = FONT if len(text) <= 10 else "tb-8"
        text_color = "#aaaaaa"
        if temp != None:
            if temp < 80:
                text_color = "#76b900"
            elif temp < 90:
                text_color = "#f5a623"
            else:
                text_color = "#d0021b"
        print("telemetry watts={} temperature={} gpu_count={}".format(watts, temp, count))

    return render.Root(
        child=render.Box(
            render.Column(
                expanded=True,
                main_align="center",
                cross_align="center",
                children=[
                    render.Text("GPU Power", font=FONT, color=text_color),
                    render.Text(text, font=value_font, color=text_color),
                ],
            ),
        )
    )
