# frozen_string_literal: true

ZeroRailsAdapter::Engine.routes.draw do
  post "/", to: "mutations#create"
  post "/mutate", to: "mutations#create"
  post "/push", to: "mutations#create"
end
