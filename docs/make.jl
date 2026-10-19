using Documenter, UPnPClient

makedocs(
    sitename = "UPnPClient.jl (Universal Plug and Play client)",
    format = Documenter.HTML(prettyurls = false),
)

deploydocs(
    repo = "github.com/wherrera10/UPnPClient.jl.git",
    devbranch = "main",  
)
