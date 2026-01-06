setInterval(async () => {
    await fetch('/api/now').then(async (res) => {
        const json = await res.json();
        const now = document.querySelector('#now');
        if (now) {
            now.innerText = json.now;
        }
    });
}, 1000);
