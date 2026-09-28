(() => {
  const form = document.querySelector("#registration-form")
  const assignment = document.querySelector("#assignment")
  const submitButton = document.querySelector("#submit-button")
  const formError = document.querySelector("#form-error")
  const nameInput = document.querySelector("#name")
  const emailInput = document.querySelector("#email")
  const nameError = document.querySelector("#name-error")
  const emailError = document.querySelector("#email-error")
  const workspaceLink = document.querySelector("#open-workspace")
  const password = document.querySelector("#workspace-password")
  const copyButton = document.querySelector("#copy-password")

  const resetErrors = () => {
    formError.textContent = ""
    nameError.textContent = ""
    emailError.textContent = ""
    nameInput.removeAttribute("aria-invalid")
    emailInput.removeAttribute("aria-invalid")
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault()
    resetErrors()

    const payload = {
      name: nameInput.value,
      email: emailInput.value,
    }

    if (!payload.name.trim() || !payload.email.trim()) {
      if (!payload.name.trim()) {
        nameError.textContent = "Enter your name."
        nameInput.setAttribute("aria-invalid", "true")
      }
      if (!payload.email.trim()) {
        emailError.textContent = "Enter your email address."
        emailInput.setAttribute("aria-invalid", "true")
      }
      return
    }

    const workspaceTab = window.open("", "_blank")
    if (workspaceTab) {
      workspaceTab.document.title = "Opening workspace…"
      workspaceTab.document.body.textContent = "Your workspace is being assigned…"
    }

    submitButton.disabled = true
    submitButton.firstElementChild.textContent = "Assigning…"

    try {
      const response = await fetch("/api/workshop/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      })
      const result = await response.json()

      if (!response.ok) {
        if (workspaceTab) workspaceTab.close()
        const fields = result.fields || {}
        if (fields.name) {
          nameError.textContent = fields.name
          nameInput.setAttribute("aria-invalid", "true")
        }
        if (fields.email) {
          emailError.textContent = fields.email
          emailInput.setAttribute("aria-invalid", "true")
        }
        formError.textContent = result.message || "We could not assign a workspace. Please ask an instructor for help."
        return
      }

      document.querySelector("#student-number").textContent = result.student_number
      password.textContent = result.workspace_password
      workspaceLink.href = result.workspace_url
      document.querySelector("#assignment-kicker").textContent = result.returning ? "WELCOME BACK" : "READY"
      document.querySelector("#assignment-title").textContent = result.returning
        ? "We found your workspace."
        : "Your workspace is ready."

      form.hidden = true
      assignment.hidden = false

      if (workspaceTab) {
        workspaceTab.opener = null
        workspaceTab.location.replace(result.workspace_url)
      } else {
        document.querySelector("#launch-note").textContent = "Your browser blocked the new tab. Use the button above to open your workspace."
      }
    } catch (error) {
      if (workspaceTab) workspaceTab.close()
      formError.textContent = "The portal could not be reached. Check your connection and try again."
    } finally {
      submitButton.disabled = false
      submitButton.firstElementChild.textContent = "Assign my workspace"
    }
  })

  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(password.textContent)
      copyButton.textContent = "Copied"
      window.setTimeout(() => { copyButton.textContent = "Copy" }, 1400)
    } catch (error) {
      const selection = window.getSelection()
      const range = document.createRange()
      range.selectNodeContents(password)
      selection.removeAllRanges()
      selection.addRange(range)
      copyButton.textContent = "Selected"
    }
  })

  document.querySelector("#start-over").addEventListener("click", () => {
    assignment.hidden = true
    form.hidden = false
    password.textContent = ""
    emailInput.focus()
  })
})()
