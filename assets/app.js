document.addEventListener("DOMContentLoaded", () => {
    const list = document.getElementById("network-list");
    const refreshBtn = document.getElementById("refresh-btn");
    const ssidInput = document.getElementById("ssid");

    function fetchNetworks() {
        list.innerHTML = "<li>Loading networks...</li>";
        fetch("/access-points.json")
            .then(response => {
                if (!response.ok) throw new Error("Network response was not ok");
                return response.json();
            })
            .then(data => {
                list.innerHTML = "";
                if (data.length === 0) {
                    list.innerHTML = "<li>No networks found.</li>";
                    return;
                }
                data.forEach(network => {
                    const li = document.createElement("li");
                    // We append elements indicating SSID and signal strength
                    li.textContent = `${network.ssid} (Signal: ${network.rssi} dBm)`;
                    li.style.cursor = "pointer";
                    li.title = "Click to select this network";
                    
                    // Clicking on a network populates the SSID field
                    li.addEventListener("click", () => {
                        ssidInput.value = network.ssid;
                        document.getElementById("password").focus();
                    });
                    
                    list.appendChild(li);
                });
            })
            .catch(error => {
                console.error("Failed to fetch networks:", error);
                list.innerHTML = "<li>Error loading networks. Please reload the page.</li>";
            });
    }

    refreshBtn.addEventListener("click", fetchNetworks);
    
    // Initial fetch when the page loads
    fetchNetworks();
});
