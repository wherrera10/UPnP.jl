using Documenter, UPnP

makedocs(
    sitename = "UPnP (Universal Plug-n-Play, SSDP / Simple Service Discovery Protocol) Module Documentation",
    format = Documenter.HTML(prettyurls = false),
)

deploydocs(
    repo = "github.com/wherrera10/UPnP.jl.git",
    devbranch = "master",  
)
