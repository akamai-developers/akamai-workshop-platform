(() => {
  const joinUrl = `${window.location.origin}/`
  document.querySelector("#join-url").textContent = joinUrl

  new QRCode(document.querySelector("#qrcode"), {
    text: joinUrl,
    width: 320,
    height: 320,
    colorDark: "#002f6c",
    colorLight: "#ffffff",
    correctLevel: QRCode.CorrectLevel.H,
  })
})()
