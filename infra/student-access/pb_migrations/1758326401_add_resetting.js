migrate((app) => {
  const collection = app.findCollectionByNameOrId("registrations")
  collection.fields.add(new BoolField({ name: "resetting" }))
  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("registrations")
  collection.fields.removeByName("resetting")
  app.save(collection)
})
