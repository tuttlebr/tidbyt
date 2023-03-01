load("render.star", "render")
load("http.star", "http")
load("math.star", "math")
load("encoding/base64.star", "base64")

DCGM_URL1 = "http://192.168.1.234:30500/api/v1/query?query=sum(DCGM_FI_DEV_POWER_USAGE)"

DCGM_URL2 = (
    "http://192.168.1.234:30500/api/v1/query?query=max(DCGM_FI_DEV_GPU_TEMP)"
)
FONT = "6x13"
# Load icon from base64 encoded data
# ICON = base64.decode()


def sum(list_values):
    result = 0
    for i in list_values:
        result += float(i)
    return math.round(result)


def main():
    response_1 = http.get(DCGM_URL1)
    response_2 = http.get(DCGM_URL2)

    if response_1.status_code != 200:
        fail("Request failed with status %d", response_1.status_code)

    watts = int(
        math.round(float(response_1.json()["data"]["result"][0]["value"][1]))
    )

    temp = int(
        math.round(float(response_2.json()["data"]["result"][0]["value"][1]))
    )
    if temp < 80:
        text_color = "#76b900"
    elif temp < 90:
        text_color = "#f5a623"
    else:
        text_color = "#d0021b"

    return render.Root(
        child=render.Box(
            render.Column(
                expanded=True,
                main_align="center",
                cross_align="center",
                children=[
                    render.Text("GPU Power", font=FONT, color=text_color),
                    render.Text(
                        "{} watts".format(watts), font=FONT, color=text_color
                    ),
                ],
            ),
        )
    )
