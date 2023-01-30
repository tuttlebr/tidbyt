load("render.star", "render")
load("http.star", "http")
load("math.star", "math")
load("encoding/base64.star", "base64")

DCGM_URL = "http://192.168.1.235:30500/api/v1/query?query=sum(DCGM_FI_DEV_POWER_USAGE)"

# Load icon from base64 encoded data
# ICON = base64.decode("""""")


def sum(list_values):
    result = 0
    for i in list_values:
        result += float(i)
    return math.round(result)


def main():
    response = http.get(DCGM_URL)
    if response.status_code != 200:
        fail("Request failed with status %d", response.status_code)

    kwh = int(math.round(
        float(response.json()["data"]["result"][0]["value"][1])))

    return render.Root(
        child=render.Column(
            expanded=True,
            main_align="center",
            cross_align="center",
            children=[
                render.Text(" GPU Power", font="6x13", color="#00ff00"),
                render.Text("{} kWh".format(kwh),
                            font="6x13", color="#00ff00"),
            ],
        ),
    )
