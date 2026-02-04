import netCDF4 as Nc
import os

# Tu carpeta de archivos
folder_nc = r'C:\Users\Mateo G\Desktop\STORCITO\Fotos\FWI'

# Busca el primer archivo .nc
archivo = [f for f in os.listdir(folder_nc) if f.endswith(".nc")][8]  # Cambia el índice para ver otros archivos
ruta_completa = os.path.join(folder_nc, archivo)

# Abre el archivo y muestra las variables
dataset = Nc.Dataset(ruta_completa)
print(f"Archivo: {archivo}")
print("--- VARIABLES DISPONIBLES ---")
print(dataset.variables.keys())
dataset.close()