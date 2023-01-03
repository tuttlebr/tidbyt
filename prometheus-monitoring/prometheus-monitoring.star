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

    kwh = math.round(float(response.json()["data"]["result"][0]["value"][1]))

    return render.Root(
        child = render.Box( # This Box exists to provide vertical centering
            render.Row(
                expanded=True, # Use as much horizontal space as possible
                main_align="space_evenly", # Controls horizontal alignment
                cross_align="center", # Controls vertical alignment
                children = [
                    render.Text("{} kWh".format(kwh), color="#76B900"),
                ],
            ),
        ),
    )